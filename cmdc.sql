--
-- PostgreSQL database dump
--

-- Dumped from database version 13.9
-- Dumped by pg_dump version 13.12

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: postgres_fdw; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgres_fdw WITH SCHEMA public;


--
-- Name: EXTENSION postgres_fdw; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION postgres_fdw IS 'foreign-data wrapper for remote PostgreSQL servers';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: carrier_account_type_enum; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.carrier_account_type_enum AS ENUM (
    'Direct',
    'BOBO',
    'BuSS',
    'Enterprise'
);


ALTER TYPE public.carrier_account_type_enum OWNER TO postgres;

--
-- Name: carrier_enum; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.carrier_enum AS ENUM (
    'Verizon',
    'TMobile'
);


ALTER TYPE public.carrier_enum OWNER TO postgres;

--
-- Name: account_location_status_update(uuid, text[], boolean, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.account_location_status_update(account_id uuid, providers text[] DEFAULT '{}'::text[], update_on_dids boolean DEFAULT true, update_on_napcos boolean DEFAULT true) RETURNS TABLE(id uuid, location_id uuid, old_account_status_code integer, new_account_status_code integer)
    LANGUAGE plpgsql
    AS $$
  DECLARE
    dids_total                integer;
    dids_online               integer;
    dids_offline              integer;
  
    dids_providers      text[];
  
    is_napco            integer;
    not_installed       integer;
    is_online           integer;
    is_offline          integer;
    is_trouble          integer;
    is_none             integer;

    is_operational boolean;
  
    old_account_status_code   integer;
    new_account_status_code   integer;
    new_account_status_id     uuid;
  
    location_id               uuid;
  
  BEGIN
    /* @param account_id : A given account table UUID
    *  @param providers : An array of text values for the names of DID providers. 
           e.g. ['net2phone', 'mixnetworks']
    *  @param update_on_dids : Boolean to determine to execute the logic for updating location status based on aggregate status of DIDs
    *  @param update_on_napcos : Boolean to determine to execute the logic for updating location status based on napco equipment status.
    *
    *  @returns The given Accounts table ID, the matching Location table ID, the old status code, and new status code. The new status code may be NULL, particularly if the new status was not calculated based on input parameters.
    *  
    *  This stored function checks and updates the aggregate status of a location (currently, stored in the Accounts table). Based on the input parameters, this function will update the location status.
    *
    *  It is based on existing / previous stored functions. Known behavior is that if a location has both DIDs and Napco equipment associated with it, the status will not be updated. Note that a location with both DIDs and Napco equipment should not occur. Also note that a location should not have a combination of DID / Line equipment from multiple providers.
    */ 
    
    -- get total dids assigned to an account location, grouped by total, online, offline
    WITH account_dids AS (
      SELECT  d."id"   AS did_id,
        ss."code" AS status_code,
        d.provider AS provider
      FROM dids d
      LEFT JOIN accounts a        ON a.id  = d."accountId"
      LEFT JOIN service_status ss ON ss.id = d."serviceStatusId"
      WHERE d."accountId" = account_id
        AND a."isOrganization" = false
    ),
    -- get the napco_equipment with all of its joined tables. found_napco contains zero rows when
    -- equipment_row.id is NOT a napco.
    found_napco   AS (
      SELECT e."id"    AS equipment_id,
            eis."code" AS eis_code,
             ss."code" AS ss_code
      FROM equipment     e
      LEFT JOIN accounts a                   ON   a.id = e."accountId"
      LEFT JOIN catalog  c                   ON   c.id = e."catalogItemId"
      LEFT JOIN equipment_install_status eis ON eis.id = e."installStatusId"
      LEFT JOIN service_status ss            ON  ss.id = e."serviceStatusId"
      WHERE c."group"     = 'napco'
        AND a.id = account_id
    )
    SELECT
      -- For location status based on dids: --
      (SELECT COUNT(*) FROM account_dids WHERE status_code in (1, 2)),
      (SELECT COUNT(*) FROM account_dids WHERE status_code = 1),
      (SELECT COUNT(*) FROM account_dids WHERE status_code = 2),
      (SELECT ARRAY(SELECT DISTINCT provider FROM account_dids)),
      
        
      -- For location status based on napco device: -- 
      -- equals 1 if the passed param equipment_row.id is a napco, else equals 0
      (SELECT COUNT(*) FROM found_napco),
      (SELECT COUNT(*) FROM found_napco WHERE eis_code NOT IN (2)),
      (SELECT COUNT(*) FROM found_napco WHERE ss_code      IN (1)),
      (SELECT COUNT(*) FROM found_napco WHERE ss_code      IN (2)),
      (SELECT COUNT(*) FROM found_napco WHERE ss_code      IN (3)),
      (SELECT COUNT(*) FROM found_napco WHERE ss_code      IN (4))
    INTO dids_total, dids_online, dids_offline, dids_providers, is_napco, not_installed, is_online, is_offline, is_trouble, is_none;
  
    -- MS-6550 - used to determine whether to use Trigger logic, or asynchronous Lambda logic for Location status calculation
    SELECT
      (SELECT operational FROM locations WHERE locations."accountId" = account_id LIMIT 1)
    INTO is_operational;
  
    -- if false, do not use this function to update location status
    IF (is_operational = false) THEN
      RETURN QUERY SELECT account_id, location_id, old_account_status_code, new_account_status_code;
      RETURN;
    END IF;

    IF (update_on_dids AND is_napco = 0 AND (providers && dids_providers OR providers = '{}' OR dids_providers IS NULL)) THEN
      -- Determine new account status based on status of lines
      IF (dids_total = 0) THEN
        new_account_status_code = 4;  -- NO dids offline or offline -> account status is None
      ELSEIF (dids_total = dids_online) THEN
        new_account_status_code = 1;  -- all dids online -> account status is Online
      ELSEIF (dids_total = dids_offline) THEN
        new_account_status_code = 2;  -- all dids offline -> account status is Offline
      ELSE
        new_account_status_code = 3;  -- mixture of online and offline dids -> account status is Trouble
      END IF;
    END IF;
  
    IF (update_on_napcos AND dids_total = 0) THEN
      IF (is_napco = 0) THEN
      -- no napcos for location - Do nothing
      ELSEIF (not_installed = 1) THEN
        new_account_status_code = 4; -- napco is not installed > account status is None 
      ELSEIF (is_online     = 1) THEN
        new_account_status_code = 1; -- napco is online -> account status is Online
      ELSEIF (is_offline    = 1) THEN
        new_account_status_code = 2; -- napco offline -> account status is Offline
      ELSEIF (is_trouble    = 1) THEN
        new_account_status_code = 3; -- napco is Trouble :)
      ELSEIF (is_none       = 1) THEN
        new_account_status_code = 4; -- napco is none -> account status is None
      END IF;
    END IF;
  
    ---- get old account status code
    SELECT ss.code
    INTO old_account_status_code 
    FROM accounts a, service_status ss 
    WHERE a.id = account_id AND a."serviceStatusId" = ss."id";
  
    ---- get the location table id for the given accountId
    SELECT locations.id
    INTO location_id
    FROM locations
    WHERE locations."accountId" = account_id;
  
    -- update account (location) status if its service status changed
    IF (old_account_status_code != new_account_status_code) THEN
      -- get new status ID
      SELECT service_status.id INTO new_account_status_id from service_status where "code" = new_account_status_code;
      UPDATE accounts
      SET "serviceStatusId" = new_account_status_id, "updatedAt" = now() at time zone 'UTC'
      WHERE accounts.id = account_id;
    END IF;
   
    RETURN QUERY SELECT account_id, location_id, old_account_status_code, new_account_status_code;
  END;
  $$;


ALTER FUNCTION public.account_location_status_update(account_id uuid, providers text[], update_on_dids boolean, update_on_napcos boolean) OWNER TO postgres;

--
-- Name: dids_account_location_status_trigger_func(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.dids_account_location_status_trigger_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- commented out, but keep to debug/log when this trigger fires
    --RAISE NOTICE 'TRIGGER INSERT did id:%', NEW.id;
    PERFORM dids_account_location_status_update(NEW);

  -- Must recalculate location status on DELETE. If a did that is Offline is
  -- deleted, its location should flip to Online
  ELSEIF TG_OP = 'DELETE' THEN
    --RAISE NOTICE 'TRIGGER DELETE did id:%', OLD.id;
    PERFORM dids_account_location_status_update(OLD);

  ELSEIF TG_OP = 'UPDATE' THEN
    --RAISE NOTICE 'TRIGGER UPDATE did id:%', NEW.id;
    PERFORM dids_account_location_status_update(NEW);
    IF (OLD."accountId" IS DISTINCT FROM NEW."accountId") THEN
      -- If old accountId is different from new one, then we must re-calculate
      -- status for old account as well as the new account
      PERFORM dids_account_location_status_update(OLD);
    END IF;
  END IF;

  RETURN NULL;
END;
$$;


ALTER FUNCTION public.dids_account_location_status_trigger_func() OWNER TO postgres;

--
-- Name: dids_account_location_status_update(record); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.dids_account_location_status_update(did_row record) RETURNS void
    LANGUAGE plpgsql
    AS $$
   DECLARE
     dids_total                integer;
     dids_online               integer;
     dids_offline              integer;
     old_account_status_code   integer;
     new_account_status_code   integer;
     new_account_status_id     uuid;

     is_operational boolean;
   BEGIN
     -- get total dids assigned to an account location, grouped by total, online, offline
     WITH account_dids AS (
       SELECT d."id"   AS did_id,
             ss."code" AS status_code
       FROM dids d
       LEFT JOIN accounts a        ON a.id  = d."accountId"
       LEFT JOIN service_status ss ON ss.id = d."serviceStatusId"
       WHERE      d."accountId" = did_row."accountId"
         AND a."isOrganization" = false
     )
     SELECT 
       (SELECT COUNT(*) FROM account_dids WHERE status_code in (1, 2)),
       (SELECT COUNT(*) FROM account_dids WHERE status_code = 1),
       (SELECT COUNT(*) FROM account_dids WHERE status_code = 2)
   
     INTO dids_total, dids_online, dids_offline;

     -- MS-6550 - used to determine whether to use Trigger logic, or asynchronous Lambda logic for Location status calculation
     SELECT
       (SELECT operational FROM locations WHERE locations."accountId" = did_row."accountId" LIMIT 1)
     INTO is_operational;
   
     -- if true, do not use this trigger function to update the location status
     IF (is_operational = true) THEN
       RETURN;
     END IF;
   
     -- Determine new account status based on status of lines
     IF (dids_total = 0) THEN
       new_account_status_code = 4;  -- NO items offline or offline -> account status is None
     ELSIF (dids_total = dids_online) THEN
       new_account_status_code = 1;  -- all dids online -> account status is Online
     ELSEIF (dids_total = dids_offline) THEN
       new_account_status_code = 2;  -- all items offline -> account status is Offline
     ELSE
       new_account_status_code = 3;  -- mixture of online and offline items -> account status is Trouble
     END IF;
   
     ---- get old account status code
     SELECT ss.code INTO old_account_status_code 
     FROM accounts a, service_status ss 
     WHERE a.id = did_row."accountId" AND a."serviceStatusId" = ss."id";
   
     -- update account (location) status if its service status changed
     IF (old_account_status_code != new_account_status_code) THEN
       -- get new status ID
       SELECT id INTO new_account_status_id from service_status where "code" = new_account_status_code;
       UPDATE accounts
       SET "serviceStatusId" = new_account_status_id, "updatedAt" = now() at time zone 'UTC'
       WHERE id = did_row."accountId";
     END IF;
    
     RETURN;
   END;
   $$;


ALTER FUNCTION public.dids_account_location_status_update(did_row record) OWNER TO postgres;

--
-- Name: equipment_account_location_status_trigger_func(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.equipment_account_location_status_trigger_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- commented out, but keep to debug/log when this trigger fires
    --RAISE NOTICE 'TRIGGER INSERT equipment id:%', NEW.id;
    PERFORM equipment_account_location_status_update(NEW);

  -- Must recalculate location status on DELETE.
  ELSEIF TG_OP = 'DELETE' THEN
    --RAISE NOTICE 'TRIGGER DELETE equipment id:%', OLD.id;
    PERFORM equipment_account_location_status_update(OLD);

  ELSEIF TG_OP = 'UPDATE' THEN
    --RAISE NOTICE 'TRIGGER UPDATE equipment id:%', NEW.id;
    PERFORM equipment_account_location_status_update(NEW);
    IF (OLD."accountId" IS DISTINCT FROM NEW."accountId") THEN
      -- If old accountId is different from new one, then we must re-calculate
      -- status for old account as well as the new account
      PERFORM equipment_account_location_status_update(OLD);
    END IF;
  END IF;

  RETURN NULL;
END;
$$;


ALTER FUNCTION public.equipment_account_location_status_trigger_func() OWNER TO postgres;

--
-- Name: equipment_account_location_status_update(record); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.equipment_account_location_status_update(equipment_row record) RETURNS void
    LANGUAGE plpgsql
    AS $$
   DECLARE
     is_napco      integer;
     not_installed integer;
     is_online     integer;
     is_offline    integer;
     is_trouble    integer;
     is_none       integer;
   
     is_operational boolean;
   
     old_account_status_code  integer;
     new_account_status_code  integer;
     new_account_status_id    uuid;
   
   BEGIN
     -- get the napco_equipment with all of its joined tables. found_napco contains zero rows when
     -- equipment_row.id is NOT a napco.
     WITH found_napco   AS (
       SELECT e."id"    AS equipment_id,
             eis."code" AS eis_code,
              ss."code" AS ss_code
       FROM equipment     e
       LEFT JOIN accounts a                   ON   a.id = e."accountId"
       LEFT JOIN catalog  c                   ON   c.id = e."catalogItemId"
       LEFT JOIN equipment_install_status eis ON eis.id = e."installStatusId"
       LEFT JOIN service_status ss            ON  ss.id = e."serviceStatusId"
       LEFT JOIN locations l                  ON  l."accountId" = e."accountId"
       WHERE c."group"     = 'napco'
         AND e.id          = equipment_row.id
     )
     SELECT
       -- equals 1 if the passed param equipment_row.id is a napco, else equals 0
       (SELECT COUNT(*) FROM found_napco),
       (SELECT COUNT(*) FROM found_napco WHERE eis_code NOT IN (2)),
       (SELECT COUNT(*) FROM found_napco WHERE ss_code      IN (1)),
       (SELECT COUNT(*) FROM found_napco WHERE ss_code      IN (2)),
       (SELECT COUNT(*) FROM found_napco WHERE ss_code      IN (3)),
       (SELECT COUNT(*) FROM found_napco WHERE ss_code      IN (4))
     INTO is_napco, not_installed, is_online, is_offline, is_trouble, is_none;
   
     -- MS-6550 - used to determine whether to use Trigger logic, or asynchronous Lambda logic for Location status calculation
     SELECT
       (SELECT operational FROM locations WHERE locations."accountId" = equipment_row."accountId" LIMIT 1)
     INTO is_operational;
   
     -- if true, do not use this trigger function to update the location status
     IF (is_operational = true) THEN
       RETURN;
     END IF;
   
     IF (is_napco = 0) THEN
       RETURN; -- not a napco equipment, do not update the account/location status, we are done
     ELSEIF (not_installed = 1) THEN
       new_account_status_code = 4; -- napco is not installed > account status is None 
     ELSEIF (is_online     = 1) THEN
       new_account_status_code = 1; -- napco is online -> account status is Online
     ELSEIF (is_offline    = 1) THEN
       new_account_status_code = 2; -- napco offline -> account status is Offline
     ELSEIF (is_trouble    = 1) THEN
       new_account_status_code = 3; -- napco is Trouble :)
     ELSEIF (is_none       = 1) THEN
       new_account_status_code = 4; -- napco is none -> account status is None
     END IF;
   
     ---- get old account status code
     SELECT ss.code
     INTO old_account_status_code 
     FROM accounts a, service_status ss 
     WHERE a.id = equipment_row."accountId" AND a."serviceStatusId" = ss."id";
   
     -- update account (location) status if its service status changed
     IF (old_account_status_code != new_account_status_code) THEN
       -- get new status ID
       SELECT id INTO new_account_status_id from service_status where "code" = new_account_status_code;
       UPDATE accounts
       SET "serviceStatusId" = new_account_status_id, "updatedAt" = now() at time zone 'UTC'
       WHERE id = equipment_row."accountId";
     END IF;
    
     RETURN;
   END;
   $$;


ALTER FUNCTION public.equipment_account_location_status_update(equipment_row record) OWNER TO postgres;

--
-- Name: cdr_db; Type: SERVER; Schema: -; Owner: postgres
--

CREATE SERVER cdr_db FOREIGN DATA WRAPPER postgres_fdw OPTIONS (
    dbname 'cmdc_cdr_dev',
    host '127.0.0.53',
    port '5431'
);


ALTER SERVER cdr_db OWNER TO postgres;

--
-- Name: USER MAPPING postgres SERVER cdr_db; Type: USER MAPPING; Schema: -; Owner: postgres
--

CREATE USER MAPPING FOR postgres SERVER cdr_db OPTIONS (
    password 'PfAXAs9B3sjgFReyEqF6pdtr',
    "user" 'postgres'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account_media; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.account_media (
    "accountsId" uuid NOT NULL,
    "mediaId" uuid NOT NULL
);


ALTER TABLE public.account_media OWNER TO postgres;

--
-- Name: account_notes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.account_notes (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    text text NOT NULL,
    "accountId" uuid,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "userName" character varying
);


ALTER TABLE public.account_notes OWNER TO postgres;

--
-- Name: accounts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.accounts (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    name character varying NOT NULL,
    "externalRef" character varying,
    "parentId" uuid,
    "addressId" uuid,
    "billingAddressId" uuid,
    "serviceStatusId" uuid NOT NULL,
    "childCount" integer DEFAULT 0 NOT NULL,
    "lastOnline" timestamp without time zone,
    "e911StatusId" uuid DEFAULT '76c2986a-3921-40eb-8d23-95bc5ed6a6ce'::uuid NOT NULL,
    "hasE911" boolean DEFAULT false,
    mpath character varying DEFAULT ''::character varying,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "logoId" uuid,
    "divisionId" uuid,
    "isOrganization" boolean DEFAULT false NOT NULL,
    "statusId" uuid,
    installation character varying,
    management character varying,
    "providerRegistration" boolean DEFAULT false NOT NULL,
    "providerTag" character varying,
    "orgProviderTag" character varying,
    "organizationId" uuid
);


ALTER TABLE public.accounts OWNER TO postgres;

--
-- Name: addresses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.addresses (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    address1 character varying NOT NULL,
    address2 character varying,
    address3 character varying,
    city character varying NOT NULL,
    state character varying(32) NOT NULL,
    "postalCode" character varying(10) NOT NULL,
    country character varying(2) NOT NULL,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "addressName" character varying(32)
);


ALTER TABLE public.addresses OWNER TO postgres;

--
-- Name: apn; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.apn (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    name character varying
);


ALTER TABLE public.apn OWNER TO postgres;

--
-- Name: auth_roles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_roles (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    name character varying NOT NULL,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL
);


ALTER TABLE public.auth_roles OWNER TO postgres;

--
-- Name: auth_roles_auth_roles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_roles_auth_roles (
    "authRolesId_1" uuid NOT NULL,
    "authRolesId_2" uuid NOT NULL
);


ALTER TABLE public.auth_roles_auth_roles OWNER TO postgres;

--
-- Name: battery_status; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.battery_status (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "equipmentId" uuid,
    "isLowBattery" boolean DEFAULT false NOT NULL,
    "isOnBackup" boolean DEFAULT false NOT NULL,
    "isMissing" boolean DEFAULT false NOT NULL,
    "needsReplacement" boolean DEFAULT false NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "isUnknown" boolean DEFAULT false,
    "powersourceId" uuid
);


ALTER TABLE public.battery_status OWNER TO postgres;

--
-- Name: brand_mac_addresses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.brand_mac_addresses (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "brandId" character varying NOT NULL,
    "macPrefix" character varying NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.brand_mac_addresses OWNER TO postgres;

--
-- Name: brands; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.brands (
    id character varying NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.brands OWNER TO postgres;

--
-- Name: bundle_catalog; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bundle_catalog (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name character varying NOT NULL,
    "routerCount" smallint DEFAULT 0,
    "gatewayCount" smallint DEFAULT 0,
    "powersourceCount" smallint DEFAULT 0,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bundle_catalog OWNER TO postgres;

--
-- Name: bundle_catalog_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bundle_catalog_items (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "bundleCatalogId" uuid,
    "routerCatalogId" uuid,
    "gatewayCatalogId" uuid,
    "powersourceCatalogId" uuid,
    "isCellular" boolean DEFAULT true,
    "isWired" boolean DEFAULT false,
    "batteryCount" smallint DEFAULT 1,
    rank smallint DEFAULT 1 NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "associatedRouterId" uuid
);


ALTER TABLE public.bundle_catalog_items OWNER TO postgres;

--
-- Name: COLUMN bundle_catalog_items."isCellular"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.bundle_catalog_items."isCellular" IS 'for Routers';


--
-- Name: COLUMN bundle_catalog_items."isWired"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.bundle_catalog_items."isWired" IS 'for Routers';


--
-- Name: COLUMN bundle_catalog_items."batteryCount"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.bundle_catalog_items."batteryCount" IS 'for Powersources';


--
-- Name: carriers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.carriers (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    name character varying NOT NULL,
    type character varying,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL
);


ALTER TABLE public.carriers OWNER TO postgres;

--
-- Name: catalog; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.catalog (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    name character varying NOT NULL,
    price numeric,
    "group" character varying,
    brand character varying,
    sku character varying,
    "wanPorts" smallint,
    "lanPorts" smallint,
    "fxoPorts" smallint,
    "pbxTemplate" character varying,
    "pbxModel" character varying,
    power character varying,
    "simCount" smallint,
    "bomId" uuid,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "sapInventoryItemId" character varying
);


ALTER TABLE public.catalog OWNER TO postgres;

--
-- Name: catalog_media; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.catalog_media (
    "catalogId" uuid NOT NULL,
    "mediaId" uuid NOT NULL
);


ALTER TABLE public.catalog_media OWNER TO postgres;

--
-- Name: cdr; Type: FOREIGN TABLE; Schema: public; Owner: postgres
--

CREATE FOREIGN TABLE public.cdr (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "callId" character varying,
    "didId" uuid,
    "timestamp" timestamp(6) without time zone NOT NULL,
    "startTime" timestamp(6) without time zone,
    "endTime" timestamp(6) without time zone NOT NULL,
    called character varying NOT NULL,
    calling character varying NOT NULL,
    direction character varying(1) NOT NULL,
    provider character varying,
    duration bigint NOT NULL,
    "releaseCode" character varying,
    "createdAt" timestamp(6) without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp(6) without time zone DEFAULT now() NOT NULL
)
SERVER cdr_db
OPTIONS (
    schema_name 'public',
    table_name 'cdr'
);


ALTER FOREIGN TABLE public.cdr OWNER TO postgres;

--
-- Name: communicators_catalog; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.communicators_catalog (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    brand character varying,
    model character varying,
    power character varying,
    "fxoPorts" smallint,
    "lanPorts" smallint,
    "simCount" smallint,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.communicators_catalog OWNER TO postgres;

--
-- Name: contact_types; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.contact_types (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    name character varying NOT NULL,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL
);


ALTER TABLE public.contact_types OWNER TO postgres;

--
-- Name: contacts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.contacts (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "firstName" character varying,
    "lastName" character varying,
    email character varying,
    "phoneWork" character varying(15),
    "phoneMobile" character varying(15),
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "orgIdOld" uuid,
    "organizationId" uuid NOT NULL
);


ALTER TABLE public.contacts OWNER TO postgres;

--
-- Name: dids; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.dids (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    value bigint NOT NULL,
    port smallint,
    "emergencyAddressRegistered" boolean DEFAULT false NOT NULL,
    "forwardValue" bigint,
    "accountId" uuid,
    "equipmentId" uuid,
    "emergencyAddressId" uuid,
    "serviceStatusId" uuid NOT NULL,
    "callerId" character varying,
    description character varying(32),
    "tempPortingNumber" character varying,
    verified boolean DEFAULT false NOT NULL,
    "awaitingSipTrunking" boolean DEFAULT false NOT NULL,
    "lastOnline" timestamp without time zone,
    "e911StatusId" uuid DEFAULT '76c2986a-3921-40eb-8d23-95bc5ed6a6ce'::uuid NOT NULL,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "lineTypeId" uuid,
    "forwardEnable" boolean DEFAULT false NOT NULL,
    "statusNotifiedAt" timestamp(6) without time zone,
    provider character varying,
    "networkProviderId" uuid,
    "gatewayId" uuid,
    extension character varying
);


ALTER TABLE public.dids OWNER TO postgres;

--
-- Name: division; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.division (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "accountId" uuid,
    "divisionName" character varying NOT NULL,
    "createdAt" timestamp(6) without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp(6) without time zone DEFAULT now() NOT NULL,
    "organizationId" uuid NOT NULL
);


ALTER TABLE public.division OWNER TO postgres;

--
-- Name: equipment; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.equipment (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "serialNumber" character varying,
    mac character varying,
    "catalogItemId" uuid,
    "accountId" uuid,
    "serviceStatusId" uuid NOT NULL,
    "installStatusId" uuid NOT NULL,
    imei character varying(15),
    "staticIp" character varying,
    description character varying(32),
    "lastOnline" timestamp without time zone,
    "ownerId" uuid DEFAULT '09357ccc-203c-47fc-85dd-fe1170999b0f'::uuid NOT NULL,
    domain character varying(255),
    "mixSubscriberSub" character varying(32),
    "mixCallLogsSub" character varying(32),
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    username character varying,
    password character varying,
    "parentId" uuid,
    "batteryStatusId" uuid,
    "statusNotifiedAt" timestamp(6) without time zone,
    "statusRetrieval" character varying,
    "providerRegistration" boolean DEFAULT false
);


ALTER TABLE public.equipment OWNER TO postgres;

--
-- Name: equipment_admin_status; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.equipment_admin_status (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    code smallint,
    name character varying
);


ALTER TABLE public.equipment_admin_status OWNER TO postgres;

--
-- Name: equipment_bundle_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.equipment_bundle_items (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "equipmentBundleId" uuid NOT NULL,
    "routerId" uuid,
    "gatewayId" uuid,
    "powersourceId" uuid,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.equipment_bundle_items OWNER TO postgres;

--
-- Name: equipment_bundles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.equipment_bundles (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "bundleCatalogId" uuid NOT NULL,
    "locationId" uuid NOT NULL,
    "adminStatusId" uuid NOT NULL,
    "ownerId" uuid NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.equipment_bundles OWNER TO postgres;

--
-- Name: equipment_install_status; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.equipment_install_status (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    code smallint NOT NULL,
    name character varying NOT NULL
);


ALTER TABLE public.equipment_install_status OWNER TO postgres;

--
-- Name: equipment_operational_status; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.equipment_operational_status (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    code smallint,
    name character varying
);


ALTER TABLE public.equipment_operational_status OWNER TO postgres;

--
-- Name: equipment_owners; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.equipment_owners (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    name character varying NOT NULL,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL
);


ALTER TABLE public.equipment_owners OWNER TO postgres;

--
-- Name: events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.events (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    message character varying NOT NULL,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL
);


ALTER TABLE public.events OWNER TO postgres;

--
-- Name: gateways; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.gateways (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "gatewayCatalogId" uuid NOT NULL,
    "adminStatusId" uuid NOT NULL,
    "operationalStatusId" uuid NOT NULL,
    "serialNumber" character varying NOT NULL,
    mac character varying NOT NULL,
    domain character varying NOT NULL,
    ip character varying,
    "lastOnline" timestamp without time zone,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    rank integer DEFAULT 1,
    "providerRegistration" boolean DEFAULT false,
    "bundleId" uuid,
    "gatewayRegistered" boolean DEFAULT false NOT NULL
);


ALTER TABLE public.gateways OWNER TO postgres;

--
-- Name: gateways_catalog; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.gateways_catalog (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    brand character varying,
    model character varying,
    power character varying,
    "fxoPorts" smallint,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.gateways_catalog OWNER TO postgres;

--
-- Name: gdmsSipServer; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."gdmsSipServer" (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "equipmentId" uuid,
    "gatewayId" uuid,
    "gdmsSipServerId" character varying
);


ALTER TABLE public."gdmsSipServer" OWNER TO postgres;

--
-- Name: gdmsSite; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."gdmsSite" (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "orgIdOld" uuid,
    "siteId" integer,
    "organizationId" uuid
);


ALTER TABLE public."gdmsSite" OWNER TO postgres;

--
-- Name: hybrids_catalog; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.hybrids_catalog (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    brand character varying,
    model character varying,
    power character varying,
    "wanPorts" smallint,
    "lanPorts" smallint,
    "fxoPorts" smallint,
    "simCount" smallint,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.hybrids_catalog OWNER TO postgres;

--
-- Name: installations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.installations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "accountId" uuid NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.installations OWNER TO postgres;

--
-- Name: line_types; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.line_types (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    name character varying NOT NULL
);


ALTER TABLE public.line_types OWNER TO postgres;

--
-- Name: location_contacts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.location_contacts (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "locationId" uuid NOT NULL,
    "contactId" uuid NOT NULL,
    "contactTypeId" uuid NOT NULL
);


ALTER TABLE public.location_contacts OWNER TO postgres;

--
-- Name: locations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.locations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp(6) without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp(6) without time zone DEFAULT now() NOT NULL,
    "accountId" uuid NOT NULL,
    "isNewConstruction" character varying,
    "telcoRooms" character varying,
    "telcoRoomsLocation" character varying,
    floor integer,
    room integer,
    "securityMeasures" character varying,
    "accessHours" character varying,
    "primaryContactId" uuid,
    "secondaryContactId" uuid,
    "e911AddressId" uuid,
    billing boolean,
    "effectiveDate" timestamp with time zone,
    operational boolean DEFAULT false NOT NULL,
    "installDate" timestamp with time zone,
    "notificationsEnabled" boolean DEFAULT false NOT NULL
);


ALTER TABLE public.locations OWNER TO postgres;

--
-- Name: netcloud; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.netcloud (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "equipmentId" uuid,
    "routerId" uuid,
    "netCloudId" character varying
);


ALTER TABLE public.netcloud OWNER TO postgres;

--
-- Name: routers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.routers (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "routerCatalogId" uuid NOT NULL,
    "adminStatusId" uuid NOT NULL,
    "operationalStatusId" uuid NOT NULL,
    "serialNumber" character varying NOT NULL,
    imei character varying NOT NULL,
    ip character varying,
    mac character varying NOT NULL,
    "userName" character varying,
    password character varying,
    "lastOnline" timestamp without time zone,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "statusRetrieval" character varying,
    "bundleId" uuid
);


ALTER TABLE public.routers OWNER TO postgres;

--
-- Name: routers_catalog; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.routers_catalog (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    brand character varying,
    model character varying,
    power character varying,
    "lanPorts" smallint,
    "simCount" smallint,
    "wanPorts" smallint,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.routers_catalog OWNER TO postgres;

--
-- Name: manufacturer_view_lookup; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.manufacturer_view_lookup AS
 WITH equipment_table AS (
         SELECT location.id AS "locationId",
            organization.id AS "organizationId",
            equipment.mac,
            catalog.brand AS "hardwareBrand",
            catalog."group" AS "equpiment_catalogGroup",
            COALESCE((netcloud."netCloudId")::text) AS "netCloudId",
            COALESCE(("gdmsSite"."siteId")::text) AS "gdms_siteId"
           FROM (((((public.equipment
             LEFT JOIN public.accounts location ON ((location.id = equipment."accountId")))
             LEFT JOIN public.accounts organization ON ((organization.id = location."parentId")))
             LEFT JOIN public.catalog ON ((catalog.id = equipment."catalogItemId")))
             LEFT JOIN public.netcloud ON ((netcloud."equipmentId" = equipment.id)))
             LEFT JOIN public."gdmsSite" ON (("gdmsSite"."orgIdOld" = organization.id)))
          WHERE ((netcloud."netCloudId" IS NOT NULL) OR ("gdmsSite"."siteId" IS NOT NULL))
        ), routers_table AS (
         SELECT location.id AS "locationId",
            organization.id AS "organizationId",
            routers.mac,
            routers_catalog.brand AS "hardwareBrand",
            NULL::text AS "?column?",
            COALESCE((netcloud."netCloudId")::text) AS "netCloudId",
            NULL::text AS "?column?"
           FROM ((((((public.routers
             LEFT JOIN public.equipment_bundle_items ON ((equipment_bundle_items."routerId" = routers.id)))
             LEFT JOIN public.equipment_bundles ON ((equipment_bundles.id = equipment_bundle_items."equipmentBundleId")))
             LEFT JOIN public.accounts location ON ((location.id = equipment_bundles."locationId")))
             LEFT JOIN public.accounts organization ON ((organization.id = location."parentId")))
             LEFT JOIN public.routers_catalog ON ((routers_catalog.id = routers."routerCatalogId")))
             LEFT JOIN public.netcloud ON ((netcloud."routerId" = routers.id)))
          WHERE (netcloud."netCloudId" IS NOT NULL)
        ), gateways_table AS (
         SELECT location.id AS "locationId",
            organization.id AS "organizationId",
            gateways.mac,
            gateways_catalog.brand AS "hardwareBrand",
            NULL::text AS "?column?",
            NULL::text AS "?column?",
            COALESCE(("gdmsSite"."siteId")::text) AS "gdms_siteId"
           FROM ((((((public.gateways
             LEFT JOIN public.equipment_bundle_items ON ((equipment_bundle_items."gatewayId" = gateways.id)))
             LEFT JOIN public.equipment_bundles ON ((equipment_bundles.id = equipment_bundle_items."equipmentBundleId")))
             LEFT JOIN public.accounts location ON ((location.id = equipment_bundles."locationId")))
             LEFT JOIN public.accounts organization ON ((organization.id = location."parentId")))
             LEFT JOIN public.gateways_catalog ON ((gateways_catalog.id = gateways."gatewayCatalogId")))
             LEFT JOIN public."gdmsSite" ON (("gdmsSite"."orgIdOld" = organization.id)))
          WHERE ("gdmsSite"."siteId" IS NOT NULL)
        )
 SELECT COALESCE(hardwaremfg."locationId") AS "locationId",
    COALESCE(hardwaremfg."organizationId") AS "organizationId",
    COALESCE(hardwaremfg.mac) AS mac,
    COALESCE(hardwaremfg."hardwareBrand") AS brand,
    hardwaremfg."equpiment_catalogGroup" AS "equipmentDeviceType",
    COALESCE(hardwaremfg."netCloudId", hardwaremfg."gdms_siteId") AS "manufacturerId"
   FROM ( SELECT equipment_table."locationId",
            equipment_table."organizationId",
            equipment_table.mac,
            equipment_table."hardwareBrand",
            equipment_table."equpiment_catalogGroup",
            equipment_table."netCloudId",
            equipment_table."gdms_siteId"
           FROM equipment_table
        UNION ALL
         SELECT routers_table."locationId",
            routers_table."organizationId",
            routers_table.mac,
            routers_table."hardwareBrand",
            routers_table."?column?",
            routers_table."netCloudId",
            routers_table."?column?_1" AS "?column?"
           FROM routers_table routers_table("locationId", "organizationId", mac, "hardwareBrand", "?column?", "netCloudId", "?column?_1")
        UNION ALL
         SELECT gateways_table."locationId",
            gateways_table."organizationId",
            gateways_table.mac,
            gateways_table."hardwareBrand",
            gateways_table."?column?",
            gateways_table."?column?_1" AS "?column?",
            gateways_table."gdms_siteId"
           FROM gateways_table gateways_table("locationId", "organizationId", mac, "hardwareBrand", "?column?", "?column?_1", "gdms_siteId")) hardwaremfg;


ALTER TABLE public.manufacturer_view_lookup OWNER TO postgres;

--
-- Name: media; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.media (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    url character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "uploadedById" uuid
);


ALTER TABLE public.media OWNER TO postgres;

--
-- Name: migrations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.migrations (
    id integer NOT NULL,
    "timestamp" bigint NOT NULL,
    name character varying NOT NULL
);


ALTER TABLE public.migrations OWNER TO postgres;

--
-- Name: migrations_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.migrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.migrations_id_seq OWNER TO postgres;

--
-- Name: migrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.migrations_id_seq OWNED BY public.migrations.id;


--
-- Name: napco_codes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.napco_codes (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp(6) without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp(6) without time zone DEFAULT now() NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    "dataType" character varying,
    description character varying,
    category character varying,
    "serviceStatusId" uuid,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL
);


ALTER TABLE public.napco_codes OWNER TO postgres;

--
-- Name: napco_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.napco_logs (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "accountNumber" character varying NOT NULL,
    "accountName" character varying NOT NULL,
    code character varying NOT NULL,
    description character varying NOT NULL,
    area character varying,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL
);


ALTER TABLE public.napco_logs OWNER TO postgres;

--
-- Name: network_types; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.network_types (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    name character varying NOT NULL
);


ALTER TABLE public.network_types OWNER TO postgres;

--
-- Name: notification_categories; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_categories (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name character varying,
    "typeId" uuid,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.notification_categories OWNER TO postgres;

--
-- Name: notification_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_settings (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "orgIdOld" uuid,
    "typeId" uuid,
    "userId" uuid,
    "organizationId" uuid NOT NULL
);


ALTER TABLE public.notification_settings OWNER TO postgres;

--
-- Name: notification_settings_emails; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_settings_emails (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "notificationSettingId" uuid,
    email character varying
);


ALTER TABLE public.notification_settings_emails OWNER TO postgres;

--
-- Name: notification_settings_locations_categories; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_settings_locations_categories (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "notificationSettingId" uuid,
    "locationId" uuid,
    "categoryId" uuid
);


ALTER TABLE public.notification_settings_locations_categories OWNER TO postgres;

--
-- Name: notification_types; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_types (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name character varying,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.notification_types OWNER TO postgres;

--
-- Name: notifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notifications (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "locationId" uuid,
    "typeId" uuid,
    "categoryId" uuid,
    message character varying
);


ALTER TABLE public.notifications OWNER TO postgres;

--
-- Name: organization_notifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.organization_notifications (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "orgIdOld" uuid,
    line boolean DEFAULT false,
    power boolean DEFAULT false,
    signal boolean DEFAULT false,
    "dataUsage" boolean DEFAULT false,
    "createdAt" timestamp(6) without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp(6) without time zone DEFAULT now() NOT NULL,
    "organizationId" uuid NOT NULL
);


ALTER TABLE public.organization_notifications OWNER TO postgres;

--
-- Name: organization_status; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.organization_status (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    code smallint NOT NULL,
    name character varying NOT NULL
);


ALTER TABLE public.organization_status OWNER TO postgres;

--
-- Name: organization_to_zoominfo_name; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.organization_to_zoominfo_name (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "organizationId" uuid NOT NULL,
    "zoomInfoName" character varying(255),
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.organization_to_zoominfo_name OWNER TO postgres;

--
-- Name: organization_users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.organization_users (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "accountId" uuid,
    "contactTypeId" uuid,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "userId" uuid NOT NULL,
    "organizationId" uuid NOT NULL
);


ALTER TABLE public.organization_users OWNER TO postgres;

--
-- Name: organizations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.organizations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name character varying,
    "addressId" uuid,
    "logoId" uuid,
    "statusId" uuid,
    installation character varying,
    management character varying,
    "providerRegistration" boolean DEFAULT false NOT NULL,
    "providerTag" character varying,
    carrier public.carrier_enum,
    "carrierAccountType" public.carrier_account_type_enum,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "networkProvider" character varying
);


ALTER TABLE public.organizations OWNER TO postgres;

--
-- Name: powersources; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.powersources (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "powersourceCatalogId" uuid NOT NULL,
    "adminStatusId" uuid NOT NULL,
    "operationalStatusId" uuid NOT NULL,
    "batteryStatusId" uuid,
    "serialNumber" character varying,
    "batterySerialNumber" character varying,
    "lastOnline" timestamp without time zone,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "routerId" uuid,
    "bundleId" uuid
);


ALTER TABLE public.powersources OWNER TO postgres;

--
-- Name: COLUMN powersources."batterySerialNumber"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.powersources."batterySerialNumber" IS 'for UPS Serial Numbers';


--
-- Name: powersources_catalog; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.powersources_catalog (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    brand character varying,
    model character varying,
    power character varying,
    "maxBatteryCount" smallint DEFAULT 1,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.powersources_catalog OWNER TO postgres;

--
-- Name: providers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.providers (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name character varying,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.providers OWNER TO postgres;

--
-- Name: service_install_status; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.service_install_status (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    code smallint NOT NULL,
    name character varying NOT NULL
);


ALTER TABLE public.service_install_status OWNER TO postgres;

--
-- Name: service_status; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.service_status (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    code smallint NOT NULL,
    name character varying NOT NULL
);


ALTER TABLE public.service_status OWNER TO postgres;

--
-- Name: service_types; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.service_types (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    name character varying NOT NULL,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL
);


ALTER TABLE public.service_types OWNER TO postgres;

--
-- Name: sim_status; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sim_status (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    code smallint NOT NULL,
    name character varying NOT NULL
);


ALTER TABLE public.sim_status OWNER TO postgres;

--
-- Name: sims; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sims (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    "iccId" character varying NOT NULL,
    "simStatusId" uuid NOT NULL,
    "locationId" uuid NOT NULL,
    "carrierId" uuid,
    "equipmentId" uuid,
    mdn character varying,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "apnId" uuid,
    slot integer,
    ownership character varying,
    "routerId" uuid
);


ALTER TABLE public.sims OWNER TO postgres;

--
-- Name: typeorm_metadata; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.typeorm_metadata (
    type character varying NOT NULL,
    database character varying,
    schema character varying,
    "table" character varying,
    name character varying,
    value text
);


ALTER TABLE public.typeorm_metadata OWNER TO postgres;

--
-- Name: users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "createdAt" timestamp without time zone DEFAULT now() NOT NULL,
    "updatedAt" timestamp without time zone DEFAULT now() NOT NULL,
    username character varying NOT NULL,
    password character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    "orgIdOld" uuid,
    active boolean DEFAULT true NOT NULL,
    "createdBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "updatedBy" uuid DEFAULT '7b8bcaec-dd9f-11ea-87d0-0242ac130003'::uuid NOT NULL,
    "isPendingConfirm" boolean DEFAULT false NOT NULL,
    "firstName" character varying,
    "lastName" character varying,
    "orgPosition" character varying,
    "phoneWork" character varying,
    "phoneMobile" character varying,
    "organizationId" uuid NOT NULL
);


ALTER TABLE public.users OWNER TO postgres;

--
-- Name: users_auth_roles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users_auth_roles (
    "usersId" uuid NOT NULL,
    "authRolesId" uuid NOT NULL
);


ALTER TABLE public.users_auth_roles OWNER TO postgres;

--
-- Name: users_notifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users_notifications (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "userId" uuid,
    "notificationId" uuid
);


ALTER TABLE public.users_notifications OWNER TO postgres;

--
-- Name: zendesk; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.zendesk (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    "organizationId" uuid NOT NULL,
    "locationId" uuid NOT NULL,
    "zendeskTypeId" uuid NOT NULL,
    "zendeskTicketId" bigint NOT NULL
);


ALTER TABLE public.zendesk OWNER TO postgres;

--
-- Name: zendesk_type; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.zendesk_type (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    code smallint,
    name character varying
);


ALTER TABLE public.zendesk_type OWNER TO postgres;

--
-- Name: migrations id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.migrations ALTER COLUMN id SET DEFAULT nextval('public.migrations_id_seq'::regclass);


--
-- Name: equipment PK_0722e1b9d6eb19f5874c1678740; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment
    ADD CONSTRAINT "PK_0722e1b9d6eb19f5874c1678740" PRIMARY KEY (id);


--
-- Name: users_notifications PK_1a7c2985c93241ca9e09d3e04f0fc99e; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users_notifications
    ADD CONSTRAINT "PK_1a7c2985c93241ca9e09d3e04f0fc99e" PRIMARY KEY (id);


--
-- Name: service_install_status PK_1a944263ffa1cb325008fce5cc0; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.service_install_status
    ADD CONSTRAINT "PK_1a944263ffa1cb325008fce5cc0" PRIMARY KEY (id);


--
-- Name: service_types PK_1dc93417a097cdee3491f39d7cc; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.service_types
    ADD CONSTRAINT "PK_1dc93417a097cdee3491f39d7cc" PRIMARY KEY (id);


--
-- Name: organization_notifications PK_3790f1b20ead44fa85c7961eb486331e; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization_notifications
    ADD CONSTRAINT "PK_3790f1b20ead44fa85c7961eb486331e" PRIMARY KEY (id);


--
-- Name: events PK_40731c7151fe4be3116e45ddf73; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT "PK_40731c7151fe4be3116e45ddf73" PRIMARY KEY (id);


--
-- Name: locations PK_4210b7892c414628be5333e888085502; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT "PK_4210b7892c414628be5333e888085502" PRIMARY KEY (id);


--
-- Name: brands PK_4a5ce207baa54b06b71aa3c1d23ccbe7; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT "PK_4a5ce207baa54b06b71aa3c1d23ccbe7" PRIMARY KEY (id);


--
-- Name: notification_settings_locations_categories PK_5791d7fa09cb40cdb9d42342293a08ba; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_settings_locations_categories
    ADD CONSTRAINT "PK_5791d7fa09cb40cdb9d42342293a08ba" PRIMARY KEY (id);


--
-- Name: accounts PK_5a7a02c20412299d198e097a8fe; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT "PK_5a7a02c20412299d198e097a8fe" PRIMARY KEY (id);


--
-- Name: napco_logs PK_5acb2c6a1fc83fbbea674bf850c; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.napco_logs
    ADD CONSTRAINT "PK_5acb2c6a1fc83fbbea674bf850c" PRIMARY KEY (id);


--
-- Name: service_status PK_6468f21b77a828e8aeac179d6c1; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.service_status
    ADD CONSTRAINT "PK_6468f21b77a828e8aeac179d6c1" PRIMARY KEY (id);


--
-- Name: sims PK_65e3dc2c5d993ede14fdf9df1ea; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sims
    ADD CONSTRAINT "PK_65e3dc2c5d993ede14fdf9df1ea" PRIMARY KEY (id);


--
-- Name: equipment_install_status PK_6dd50d1ece2729746074c1c093d; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_install_status
    ADD CONSTRAINT "PK_6dd50d1ece2729746074c1c093d" PRIMARY KEY (id);


--
-- Name: napco_codes PK_73217cc0a322c4c84e17c40bfda; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.napco_codes
    ADD CONSTRAINT "PK_73217cc0a322c4c84e17c40bfda" PRIMARY KEY (id);


--
-- Name: addresses PK_745d8f43d3af10ab8247465e450; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT "PK_745d8f43d3af10ab8247465e450" PRIMARY KEY (id);


--
-- Name: providers PK_77722a444cac4ff5a41aa146cb14e84b; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.providers
    ADD CONSTRAINT "PK_77722a444cac4ff5a41aa146cb14e84b" PRIMARY KEY (id);


--
-- Name: brand_mac_addresses PK_782163d8478445a883f027c2f17937a3; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.brand_mac_addresses
    ADD CONSTRAINT "PK_782163d8478445a883f027c2f17937a3" PRIMARY KEY (id);


--
-- Name: catalog PK_782754bded12b4e75ad4afff913; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.catalog
    ADD CONSTRAINT "PK_782754bded12b4e75ad4afff913" PRIMARY KEY (id);


--
-- Name: migrations PK_8c82d7f526340ab734260ea46be; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.migrations
    ADD CONSTRAINT "PK_8c82d7f526340ab734260ea46be" PRIMARY KEY (id);


--
-- Name: auth_roles_auth_roles PK_8d3a4e8f3b2d8bb834419bc58f0; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_roles_auth_roles
    ADD CONSTRAINT "PK_8d3a4e8f3b2d8bb834419bc58f0" PRIMARY KEY ("authRolesId_1", "authRolesId_2");


--
-- Name: apn PK_975c3f7cb4c841f49f29a486f97df520; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.apn
    ADD CONSTRAINT "PK_975c3f7cb4c841f49f29a486f97df520" PRIMARY KEY (id);


--
-- Name: users PK_a3ffb1c0c8416b9fc6f907b7433; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT "PK_a3ffb1c0c8416b9fc6f907b7433" PRIMARY KEY (id);


--
-- Name: network_types PK_a56d8184627e5a954ff84834b1f; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.network_types
    ADD CONSTRAINT "PK_a56d8184627e5a954ff84834b1f" PRIMARY KEY (id);


--
-- Name: notification_settings PK_a77d0830d06a4d8299ed247d59450847; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_settings
    ADD CONSTRAINT "PK_a77d0830d06a4d8299ed247d59450847" PRIMARY KEY (id);


--
-- Name: equipment_admin_status PK_a7a52ca205c248a3a7e24d389e8924b7; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_admin_status
    ADD CONSTRAINT "PK_a7a52ca205c248a3a7e24d389e8924b7" PRIMARY KEY (id);


--
-- Name: account_media PK_ad7749cb92d029b221f23b2c4a9; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account_media
    ADD CONSTRAINT "PK_ad7749cb92d029b221f23b2c4a9" PRIMARY KEY ("accountsId", "mediaId");


--
-- Name: organization_users PK_b306ee42fe2a4700b31e3e3353cf55c8; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization_users
    ADD CONSTRAINT "PK_b306ee42fe2a4700b31e3e3353cf55c8" PRIMARY KEY (id);


--
-- Name: sim_status PK_b8796a50a5c36cbda2b810c057c; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sim_status
    ADD CONSTRAINT "PK_b8796a50a5c36cbda2b810c057c" PRIMARY KEY (id);


--
-- Name: contacts PK_b99cd40cfd66a99f1571f4f72e6; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT "PK_b99cd40cfd66a99f1571f4f72e6" PRIMARY KEY (id);


--
-- Name: notification_types PK_bd37a9d82f054509b8f0b79b57dea60e; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_types
    ADD CONSTRAINT "PK_bd37a9d82f054509b8f0b79b57dea60e" PRIMARY KEY (id);


--
-- Name: bundle_catalog PK_bundle_catalog_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bundle_catalog
    ADD CONSTRAINT "PK_bundle_catalog_id" PRIMARY KEY (id);


--
-- Name: bundle_catalog_items PK_bundle_catalog_items_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bundle_catalog_items
    ADD CONSTRAINT "PK_bundle_catalog_items_id" PRIMARY KEY (id);


--
-- Name: dids PK_c1c702cc02c5a54657fbfc0317a; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dids
    ADD CONSTRAINT "PK_c1c702cc02c5a54657fbfc0317a" PRIMARY KEY (id);


--
-- Name: contact_types PK_cfbbcaf06c9ffa278519a0ff810; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact_types
    ADD CONSTRAINT "PK_cfbbcaf06c9ffa278519a0ff810" PRIMARY KEY (id);


--
-- Name: communicators_catalog PK_communicators_catalog_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.communicators_catalog
    ADD CONSTRAINT "PK_communicators_catalog_id" PRIMARY KEY (id);


--
-- Name: organization_status PK_d0c05ce3ac8c413a9238c46b9725b7ea; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization_status
    ADD CONSTRAINT "PK_d0c05ce3ac8c413a9238c46b9725b7ea" PRIMARY KEY (id);


--
-- Name: equipment_operational_status PK_d583e30b5db7463591e23f618a3bc4c0; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_operational_status
    ADD CONSTRAINT "PK_d583e30b5db7463591e23f618a3bc4c0" PRIMARY KEY (id);


--
-- Name: catalog_media PK_e4134364d19ca37b02f27ef0e09; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.catalog_media
    ADD CONSTRAINT "PK_e4134364d19ca37b02f27ef0e09" PRIMARY KEY ("catalogId", "mediaId");


--
-- Name: notification_settings_emails PK_e58da9dca5714a7ca829b65c1b79f2bb; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_settings_emails
    ADD CONSTRAINT "PK_e58da9dca5714a7ca829b65c1b79f2bb" PRIMARY KEY (id);


--
-- Name: users_auth_roles PK_ecd54b2921f9a733ce91bf136fa; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users_auth_roles
    ADD CONSTRAINT "PK_ecd54b2921f9a733ce91bf136fa" PRIMARY KEY ("usersId", "authRolesId");


--
-- Name: notifications PK_efe7f9fe14b543388d2a0e5b9aef218d; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT "PK_efe7f9fe14b543388d2a0e5b9aef218d" PRIMARY KEY (id);


--
-- Name: equipment_bundle_items PK_equipment_bundle_items_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_bundle_items
    ADD CONSTRAINT "PK_equipment_bundle_items_id" PRIMARY KEY (id);


--
-- Name: equipment_bundles PK_equipment_bundles_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_bundles
    ADD CONSTRAINT "PK_equipment_bundles_id" PRIMARY KEY (id);


--
-- Name: media PK_f4e0fcac36e050de337b670d8bd; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.media
    ADD CONSTRAINT "PK_f4e0fcac36e050de337b670d8bd" PRIMARY KEY (id);


--
-- Name: auth_roles PK_fa9e7a265809eafa9e1f47122e2; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_roles
    ADD CONSTRAINT "PK_fa9e7a265809eafa9e1f47122e2" PRIMARY KEY (id);


--
-- Name: carriers PK_fe886e72b3d9f67da3ce70f4368; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.carriers
    ADD CONSTRAINT "PK_fe886e72b3d9f67da3ce70f4368" PRIMARY KEY (id);


--
-- Name: notification_categories PK_ff147ecca2bd414db9d2b4d6ae691773; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_categories
    ADD CONSTRAINT "PK_ff147ecca2bd414db9d2b4d6ae691773" PRIMARY KEY (id);


--
-- Name: gateways_catalog PK_gateways_catalog_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateways_catalog
    ADD CONSTRAINT "PK_gateways_catalog_id" PRIMARY KEY (id);


--
-- Name: gateways PK_gateways_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateways
    ADD CONSTRAINT "PK_gateways_id" PRIMARY KEY (id);


--
-- Name: gdmsSipServer PK_gdmsSipServer_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."gdmsSipServer"
    ADD CONSTRAINT "PK_gdmsSipServer_id" PRIMARY KEY (id);


--
-- Name: gdmsSite PK_gdms_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."gdmsSite"
    ADD CONSTRAINT "PK_gdms_id" PRIMARY KEY (id);


--
-- Name: hybrids_catalog PK_hybrids_catalog_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.hybrids_catalog
    ADD CONSTRAINT "PK_hybrids_catalog_id" PRIMARY KEY (id);


--
-- Name: installations PK_installations_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.installations
    ADD CONSTRAINT "PK_installations_id" PRIMARY KEY (id);


--
-- Name: netcloud PK_netcloud_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.netcloud
    ADD CONSTRAINT "PK_netcloud_id" PRIMARY KEY (id);


--
-- Name: organizations PK_organization_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT "PK_organization_id" PRIMARY KEY (id);


--
-- Name: powersources_catalog PK_powersources_catalog_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.powersources_catalog
    ADD CONSTRAINT "PK_powersources_catalog_id" PRIMARY KEY (id);


--
-- Name: powersources PK_powersources_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.powersources
    ADD CONSTRAINT "PK_powersources_id" PRIMARY KEY (id);


--
-- Name: routers_catalog PK_routers_catalog_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routers_catalog
    ADD CONSTRAINT "PK_routers_catalog_id" PRIMARY KEY (id);


--
-- Name: routers PK_routers_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routers
    ADD CONSTRAINT "PK_routers_id" PRIMARY KEY (id);


--
-- Name: zendesk_type PK_zendeskType_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zendesk_type
    ADD CONSTRAINT "PK_zendeskType_id" PRIMARY KEY (id);


--
-- Name: zendesk PK_zendesk_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zendesk
    ADD CONSTRAINT "PK_zendesk_id" PRIMARY KEY (id);


--
-- Name: catalog REL_0305a997c55275deb3cd87b683; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.catalog
    ADD CONSTRAINT "REL_0305a997c55275deb3cd87b683" UNIQUE ("bomId");


--
-- Name: dids UQ_154141b721056dc1d0bbb663df4; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dids
    ADD CONSTRAINT "UQ_154141b721056dc1d0bbb663df4" UNIQUE ("tempPortingNumber");


--
-- Name: dids UQ_aaa6092cd11121d952a67465f5a; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dids
    ADD CONSTRAINT "UQ_aaa6092cd11121d952a67465f5a" UNIQUE (value);


--
-- Name: bundle_catalog UQ_bundle_catalog_name; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bundle_catalog
    ADD CONSTRAINT "UQ_bundle_catalog_name" UNIQUE (name);


--
-- Name: napco_codes UQ_f3a1303c7254a46d096080dd0db; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.napco_codes
    ADD CONSTRAINT "UQ_f3a1303c7254a46d096080dd0db" UNIQUE (code);


--
-- Name: users UQ_fe0bb3f6520ee0469504521e710; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT "UQ_fe0bb3f6520ee0469504521e710" UNIQUE (username);


--
-- Name: gateways UQ_gateways_ip; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateways
    ADD CONSTRAINT "UQ_gateways_ip" UNIQUE (ip);


--
-- Name: gateways UQ_gateways_mac; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateways
    ADD CONSTRAINT "UQ_gateways_mac" UNIQUE (mac);


--
-- Name: gateways UQ_gateways_serialNumber; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateways
    ADD CONSTRAINT "UQ_gateways_serialNumber" UNIQUE ("serialNumber");


--
-- Name: powersources UQ_powersources_batterySerialNumber; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.powersources
    ADD CONSTRAINT "UQ_powersources_batterySerialNumber" UNIQUE ("batterySerialNumber");


--
-- Name: powersources UQ_powersources_serialNumber; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.powersources
    ADD CONSTRAINT "UQ_powersources_serialNumber" UNIQUE ("serialNumber");


--
-- Name: routers UQ_routers_ip; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routers
    ADD CONSTRAINT "UQ_routers_ip" UNIQUE (ip);


--
-- Name: routers UQ_routers_mac; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routers
    ADD CONSTRAINT "UQ_routers_mac" UNIQUE (mac);


--
-- Name: routers UQ_routers_serialNumber; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routers
    ADD CONSTRAINT "UQ_routers_serialNumber" UNIQUE ("serialNumber");


--
-- Name: account_notes account_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account_notes
    ADD CONSTRAINT account_notes_pkey PRIMARY KEY (id);


--
-- Name: catalog catalog_sapInventoryItemId_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.catalog
    ADD CONSTRAINT "catalog_sapInventoryItemId_key" UNIQUE ("sapInventoryItemId");


--
-- Name: division division_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.division
    ADD CONSTRAINT division_pkey PRIMARY KEY (id);


--
-- Name: equipment_owners equipment_owners_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_owners
    ADD CONSTRAINT equipment_owners_pkey PRIMARY KEY (id);


--
-- Name: installations installations_accountId_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.installations
    ADD CONSTRAINT "installations_accountId_key" UNIQUE ("accountId");


--
-- Name: line_types line_types_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.line_types
    ADD CONSTRAINT line_types_name_key UNIQUE (name);


--
-- Name: line_types line_types_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.line_types
    ADD CONSTRAINT line_types_pkey PRIMARY KEY (id);


--
-- Name: location_contacts location_contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.location_contacts
    ADD CONSTRAINT location_contacts_pkey PRIMARY KEY (id);


--
-- Name: equipment ms1915; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment
    ADD CONSTRAINT ms1915 UNIQUE ("serialNumber");


--
-- Name: organization_to_zoominfo_name organization_to_zoominfo_name_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization_to_zoominfo_name
    ADD CONSTRAINT organization_to_zoominfo_name_pkey PRIMARY KEY (id);


--
-- Name: accounts providertag_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT providertag_unique UNIQUE ("providerTag");


--
-- Name: battery_status tent_battery_status_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.battery_status
    ADD CONSTRAINT tent_battery_status_pkey PRIMARY KEY (id);


--
-- Name: IDX_2fe7624375452e3c7ffdead889; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_2fe7624375452e3c7ffdead889" ON public.account_media USING btree ("mediaId");


--
-- Name: IDX_3ca7dc31a4a67c0650eb5c38b5; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_3ca7dc31a4a67c0650eb5c38b5" ON public.auth_roles_auth_roles USING btree ("authRolesId_1");


--
-- Name: IDX_63795852187f8e6a373f2841a3; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_63795852187f8e6a373f2841a3" ON public.auth_roles_auth_roles USING btree ("authRolesId_2");


--
-- Name: IDX_7ce00b77faa1d9ecd42ee5cbdc; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_7ce00b77faa1d9ecd42ee5cbdc" ON public.account_media USING btree ("accountsId");


--
-- Name: IDX_8c7d79992e03f68c448d2a55b0; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_8c7d79992e03f68c448d2a55b0" ON public.users_auth_roles USING btree ("authRolesId");


--
-- Name: IDX_974d57dad922602a3579de0496; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_974d57dad922602a3579de0496" ON public.users_auth_roles USING btree ("usersId");


--
-- Name: IDX_battery_status_powersourceId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_battery_status_powersourceId" ON public.battery_status USING btree ("powersourceId");


--
-- Name: IDX_bundle_catalog_items_bundleCatalogId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_bundle_catalog_items_bundleCatalogId" ON public.bundle_catalog_items USING btree ("bundleCatalogId");


--
-- Name: IDX_bundle_catalog_items_gatewayCatalogId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_bundle_catalog_items_gatewayCatalogId" ON public.bundle_catalog_items USING btree ("gatewayCatalogId");


--
-- Name: IDX_bundle_catalog_items_powersourceCatalogId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_bundle_catalog_items_powersourceCatalogId" ON public.bundle_catalog_items USING btree ("powersourceCatalogId");


--
-- Name: IDX_bundle_catalog_items_routerCatalogId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_bundle_catalog_items_routerCatalogId" ON public.bundle_catalog_items USING btree ("routerCatalogId");


--
-- Name: IDX_bundle_catalog_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_bundle_catalog_name" ON public.bundle_catalog USING btree (name);


--
-- Name: IDX_db2c36763ba04fd5d18be3d32f; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_db2c36763ba04fd5d18be3d32f" ON public.catalog_media USING btree ("mediaId");


--
-- Name: IDX_dids_gatewayId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_dids_gatewayId" ON public.dids USING btree ("gatewayId");


--
-- Name: IDX_e1298fe510749433d9f5441604; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_e1298fe510749433d9f5441604" ON public.catalog_media USING btree ("catalogId");


--
-- Name: IDX_equipmentId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_equipmentId" ON public.netcloud USING btree ("equipmentId");


--
-- Name: IDX_equipment_bundle_items_equipmentBundleId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_equipment_bundle_items_equipmentBundleId" ON public.equipment_bundle_items USING btree ("equipmentBundleId");


--
-- Name: IDX_equipment_bundle_items_gatewayId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_equipment_bundle_items_gatewayId" ON public.equipment_bundle_items USING btree ("gatewayId");


--
-- Name: IDX_equipment_bundle_items_powersourceId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_equipment_bundle_items_powersourceId" ON public.equipment_bundle_items USING btree ("powersourceId");


--
-- Name: IDX_equipment_bundle_items_routerId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_equipment_bundle_items_routerId" ON public.equipment_bundle_items USING btree ("routerId");


--
-- Name: IDX_equipment_bundles_adminStatusId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_equipment_bundles_adminStatusId" ON public.equipment_bundles USING btree ("adminStatusId");


--
-- Name: IDX_equipment_bundles_bundleCatalogId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_equipment_bundles_bundleCatalogId" ON public.equipment_bundles USING btree ("bundleCatalogId");


--
-- Name: IDX_equipment_bundles_locationId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_equipment_bundles_locationId" ON public.equipment_bundles USING btree ("locationId");


--
-- Name: IDX_equipment_bundles_ownerId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_equipment_bundles_ownerId" ON public.equipment_bundles USING btree ("ownerId");


--
-- Name: IDX_equipment_imei; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_equipment_imei" ON public.equipment USING btree (imei);


--
-- Name: IDX_equipment_mac; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_equipment_mac" ON public.equipment USING btree (mac);


--
-- Name: IDX_equipment_serialNumber; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_equipment_serialNumber" ON public.equipment USING btree ("serialNumber");


--
-- Name: IDX_equipment_staticIp; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_equipment_staticIp" ON public.equipment USING btree ("staticIp");


--
-- Name: IDX_gatewayId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_gatewayId" ON public."gdmsSipServer" USING btree ("gatewayId");


--
-- Name: IDX_gateways_adminStatusId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_gateways_adminStatusId" ON public.gateways USING btree ("adminStatusId");


--
-- Name: IDX_gateways_gatewayCatalogId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_gateways_gatewayCatalogId" ON public.gateways USING btree ("gatewayCatalogId");


--
-- Name: IDX_gateways_operationalStatusId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_gateways_operationalStatusId" ON public.gateways USING btree ("operationalStatusId");


--
-- Name: IDX_gateways_serialNumber; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_gateways_serialNumber" ON public.gateways USING btree ("serialNumber");


--
-- Name: IDX_organizationId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_organizationId" ON public."gdmsSite" USING btree ("orgIdOld");


--
-- Name: IDX_powersources_adminStatusId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_powersources_adminStatusId" ON public.powersources USING btree ("adminStatusId");


--
-- Name: IDX_powersources_operationalStatusId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_powersources_operationalStatusId" ON public.powersources USING btree ("operationalStatusId");


--
-- Name: IDX_powersources_powersourceCatalogId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_powersources_powersourceCatalogId" ON public.powersources USING btree ("powersourceCatalogId");


--
-- Name: IDX_powersources_routerId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_powersources_routerId" ON public.powersources USING btree ("routerId");


--
-- Name: IDX_powersources_serialNumber; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_powersources_serialNumber" ON public.powersources USING btree ("serialNumber");


--
-- Name: IDX_routerId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_routerId" ON public.netcloud USING btree ("routerId");


--
-- Name: IDX_routers_adminStatusId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_routers_adminStatusId" ON public.routers USING btree ("adminStatusId");


--
-- Name: IDX_routers_catalog_brand; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_routers_catalog_brand" ON public.routers_catalog USING btree (brand);


--
-- Name: IDX_routers_operationalStatusId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_routers_operationalStatusId" ON public.routers USING btree ("operationalStatusId");


--
-- Name: IDX_routers_routerCatalogId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_routers_routerCatalogId" ON public.routers USING btree ("routerCatalogId");


--
-- Name: IDX_routers_serialNumber; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_routers_serialNumber" ON public.routers USING btree ("serialNumber");


--
-- Name: IDX_sims_equipmentId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_sims_equipmentId" ON public.sims USING btree ("equipmentId");


--
-- Name: IDX_sims_routerId; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "IDX_sims_routerId" ON public.sims USING btree ("routerId");


--
-- Name: dids_account_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX dids_account_index ON public.dids USING btree ("accountId");


--
-- Name: equipment_account_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX equipment_account_index ON public.equipment USING btree ("accountId");


--
-- Name: gdmssite_organization_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX gdmssite_organization_index ON public."gdmsSite" USING btree ("organizationId");


--
-- Name: idx_napcologs_accountnumber; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_napcologs_accountnumber ON public.napco_logs USING btree ("accountNumber");


--
-- Name: dids dids_account_location_status_delete_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER dids_account_location_status_delete_trigger AFTER DELETE ON public.dids FOR EACH ROW EXECUTE FUNCTION public.dids_account_location_status_trigger_func();


--
-- Name: dids dids_account_location_status_insert_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER dids_account_location_status_insert_trigger AFTER INSERT ON public.dids FOR EACH ROW EXECUTE FUNCTION public.dids_account_location_status_trigger_func();


--
-- Name: dids dids_account_location_status_update_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER dids_account_location_status_update_trigger AFTER UPDATE ON public.dids FOR EACH ROW EXECUTE FUNCTION public.dids_account_location_status_trigger_func();


--
-- Name: equipment equipment_account_location_status_delete_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER equipment_account_location_status_delete_trigger AFTER DELETE ON public.equipment FOR EACH ROW EXECUTE FUNCTION public.equipment_account_location_status_trigger_func();


--
-- Name: equipment equipment_account_location_status_insert_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER equipment_account_location_status_insert_trigger AFTER INSERT ON public.equipment FOR EACH ROW EXECUTE FUNCTION public.equipment_account_location_status_trigger_func();


--
-- Name: equipment equipment_account_location_status_update_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER equipment_account_location_status_update_trigger AFTER UPDATE ON public.equipment FOR EACH ROW EXECUTE FUNCTION public.equipment_account_location_status_trigger_func();


--
-- Name: equipment FK_044bd31ad20fdef8843c9e6fae1; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment
    ADD CONSTRAINT "FK_044bd31ad20fdef8843c9e6fae1" FOREIGN KEY ("catalogItemId") REFERENCES public.catalog(id);


--
-- Name: equipment FK_04a884a357461ceadde62c4da2e; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment
    ADD CONSTRAINT "FK_04a884a357461ceadde62c4da2e" FOREIGN KEY ("accountId") REFERENCES public.accounts(id);


--
-- Name: equipment FK_1e24fa37cf900b11288b0779c1b; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment
    ADD CONSTRAINT "FK_1e24fa37cf900b11288b0779c1b" FOREIGN KEY ("installStatusId") REFERENCES public.equipment_install_status(id);


--
-- Name: organization_users FK_221107dfcae842878a0ffb19b30699fb; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization_users
    ADD CONSTRAINT "FK_221107dfcae842878a0ffb19b30699fb" FOREIGN KEY ("accountId") REFERENCES public.accounts(id);


--
-- Name: notifications FK_24e3db43218147569d7683a71867dfe4; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT "FK_24e3db43218147569d7683a71867dfe4" FOREIGN KEY ("typeId") REFERENCES public.notification_types(id);


--
-- Name: sims FK_28ef187ef5c58ad0b4bf05439b7; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sims
    ADD CONSTRAINT "FK_28ef187ef5c58ad0b4bf05439b7" FOREIGN KEY ("carrierId") REFERENCES public.carriers(id);


--
-- Name: account_media FK_2fe7624375452e3c7ffdead8891; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account_media
    ADD CONSTRAINT "FK_2fe7624375452e3c7ffdead8891" FOREIGN KEY ("mediaId") REFERENCES public.media(id) ON DELETE CASCADE;


--
-- Name: dids FK_362c534249248c98c2043bdbda8; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dids
    ADD CONSTRAINT "FK_362c534249248c98c2043bdbda8" FOREIGN KEY ("accountId") REFERENCES public.accounts(id);


--
-- Name: dids FK_38aa28d52e4b7fdf50821a8118e; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dids
    ADD CONSTRAINT "FK_38aa28d52e4b7fdf50821a8118e" FOREIGN KEY ("emergencyAddressId") REFERENCES public.addresses(id);


--
-- Name: notification_settings FK_3b99edd7261344c79db283e8d64e55ea; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_settings
    ADD CONSTRAINT "FK_3b99edd7261344c79db283e8d64e55ea" FOREIGN KEY ("userId") REFERENCES public.users(id);


--
-- Name: auth_roles_auth_roles FK_3ca7dc31a4a67c0650eb5c38b5d; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_roles_auth_roles
    ADD CONSTRAINT "FK_3ca7dc31a4a67c0650eb5c38b5d" FOREIGN KEY ("authRolesId_1") REFERENCES public.auth_roles(id) ON DELETE CASCADE;


--
-- Name: sims FK_405586b474d15236cc645ff97e9; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sims
    ADD CONSTRAINT "FK_405586b474d15236cc645ff97e9" FOREIGN KEY ("simStatusId") REFERENCES public.sim_status(id);


--
-- Name: users FK_42bba679e348de51a699fb0a803; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT "FK_42bba679e348de51a699fb0a803" FOREIGN KEY ("orgIdOld") REFERENCES public.accounts(id);


--
-- Name: dids FK_43996e8ca13df946e475414a785; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dids
    ADD CONSTRAINT "FK_43996e8ca13df946e475414a785" FOREIGN KEY ("equipmentId") REFERENCES public.equipment(id);


--
-- Name: media FK_4974d31d47717ebefc8b613eb27; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.media
    ADD CONSTRAINT "FK_4974d31d47717ebefc8b613eb27" FOREIGN KEY ("uploadedById") REFERENCES public.users(id);


--
-- Name: dids FK_4b6dc353ac3544e1b5491bd086fdb087; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dids
    ADD CONSTRAINT "FK_4b6dc353ac3544e1b5491bd086fdb087" FOREIGN KEY ("networkProviderId") REFERENCES public.providers(id);


--
-- Name: organization_users FK_5bec664368924b4796abaafaf8c094d0; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization_users
    ADD CONSTRAINT "FK_5bec664368924b4796abaafaf8c094d0" FOREIGN KEY ("contactTypeId") REFERENCES public.contact_types(id);


--
-- Name: locations FK_60ae5c33f2a44176a1b27f3a6a381a18; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT "FK_60ae5c33f2a44176a1b27f3a6a381a18" FOREIGN KEY ("secondaryContactId") REFERENCES public.contacts(id);


--
-- Name: auth_roles_auth_roles FK_63795852187f8e6a373f2841a36; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_roles_auth_roles
    ADD CONSTRAINT "FK_63795852187f8e6a373f2841a36" FOREIGN KEY ("authRolesId_2") REFERENCES public.auth_roles(id) ON DELETE CASCADE;


--
-- Name: users_notifications FK_67feabe9ead94172aa295aef356aca80; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users_notifications
    ADD CONSTRAINT "FK_67feabe9ead94172aa295aef356aca80" FOREIGN KEY ("notificationId") REFERENCES public.notifications(id);


--
-- Name: sims FK_70ea7d7fa1577cf241f45eab595; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sims
    ADD CONSTRAINT "FK_70ea7d7fa1577cf241f45eab595" FOREIGN KEY ("equipmentId") REFERENCES public.equipment(id);


--
-- Name: locations FK_769f35522b32406d89e9ca62eb46da81; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT "FK_769f35522b32406d89e9ca62eb46da81" FOREIGN KEY ("accountId") REFERENCES public.accounts(id);


--
-- Name: account_media FK_7ce00b77faa1d9ecd42ee5cbdc9; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account_media
    ADD CONSTRAINT "FK_7ce00b77faa1d9ecd42ee5cbdc9" FOREIGN KEY ("accountsId") REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: napco_codes FK_85659cdb81769e564f36b85ddeb; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.napco_codes
    ADD CONSTRAINT "FK_85659cdb81769e564f36b85ddeb" FOREIGN KEY ("serviceStatusId") REFERENCES public.service_status(id);


--
-- Name: accounts FK_89ea2479ffded881b409cc92011; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT "FK_89ea2479ffded881b409cc92011" FOREIGN KEY ("addressId") REFERENCES public.addresses(id);


--
-- Name: notifications FK_8b46c80ae87d456fa049e8cd87c0e5f6; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT "FK_8b46c80ae87d456fa049e8cd87c0e5f6" FOREIGN KEY ("locationId") REFERENCES public.accounts(id);


--
-- Name: accounts FK_8bb9478a90ef09b22562e1a6dfa; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT "FK_8bb9478a90ef09b22562e1a6dfa" FOREIGN KEY ("serviceStatusId") REFERENCES public.service_status(id);


--
-- Name: equipment FK_8c675a8a1fb7097c17e3280d1df; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment
    ADD CONSTRAINT "FK_8c675a8a1fb7097c17e3280d1df" FOREIGN KEY ("ownerId") REFERENCES public.equipment_owners(id);


--
-- Name: users_auth_roles FK_8c7d79992e03f68c448d2a55b0a; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users_auth_roles
    ADD CONSTRAINT "FK_8c7d79992e03f68c448d2a55b0a" FOREIGN KEY ("authRolesId") REFERENCES public.auth_roles(id) ON DELETE CASCADE;


--
-- Name: notification_categories FK_8f03971d322d4e03a557659474424476; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_categories
    ADD CONSTRAINT "FK_8f03971d322d4e03a557659474424476" FOREIGN KEY ("typeId") REFERENCES public.notification_types(id);


--
-- Name: notification_settings_locations_categories FK_94d22f0d80044973b9e400365f352c75; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_settings_locations_categories
    ADD CONSTRAINT "FK_94d22f0d80044973b9e400365f352c75" FOREIGN KEY ("locationId") REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: users_auth_roles FK_974d57dad922602a3579de0496b; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users_auth_roles
    ADD CONSTRAINT "FK_974d57dad922602a3579de0496b" FOREIGN KEY ("usersId") REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: notification_settings_emails FK_99ab983202d5459cb8c1854d64b788a1; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_settings_emails
    ADD CONSTRAINT "FK_99ab983202d5459cb8c1854d64b788a1" FOREIGN KEY ("notificationSettingId") REFERENCES public.notification_settings(id) ON DELETE CASCADE;


--
-- Name: equipment FK_9ee41f9e3e708e620c16d4a2ce1; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment
    ADD CONSTRAINT "FK_9ee41f9e3e708e620c16d4a2ce1" FOREIGN KEY ("serviceStatusId") REFERENCES public.service_status(id);


--
-- Name: accounts FK_a26200f20d6c4555edbb889f397; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT "FK_a26200f20d6c4555edbb889f397" FOREIGN KEY ("billingAddressId") REFERENCES public.addresses(id);


--
-- Name: dids FK_a3fb7a55c67d681e21ff972ae38; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dids
    ADD CONSTRAINT "FK_a3fb7a55c67d681e21ff972ae38" FOREIGN KEY ("e911StatusId") REFERENCES public.service_status(id);


--
-- Name: accounts FK_a3fb7a55c67d681e21ff972ae38; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT "FK_a3fb7a55c67d681e21ff972ae38" FOREIGN KEY ("e911StatusId") REFERENCES public.service_status(id);


--
-- Name: notification_settings FK_ab51793135254aa2a42e808a755ff74e; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_settings
    ADD CONSTRAINT "FK_ab51793135254aa2a42e808a755ff74e" FOREIGN KEY ("orgIdOld") REFERENCES public.accounts(id);


--
-- Name: installations FK_account_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.installations
    ADD CONSTRAINT "FK_account_id" FOREIGN KEY ("accountId") REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: accounts FK_adb0c7a18c3c435ba3877c7d48b; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT "FK_adb0c7a18c3c435ba3877c7d48b" FOREIGN KEY ("logoId") REFERENCES public.media(id);


--
-- Name: sims FK_af361eb353294b4880ba4774996debff; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sims
    ADD CONSTRAINT "FK_af361eb353294b4880ba4774996debff" FOREIGN KEY ("apnId") REFERENCES public.apn(id);


--
-- Name: users_notifications FK_ba79d85693b94a4ca215490f586e2bca; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users_notifications
    ADD CONSTRAINT "FK_ba79d85693b94a4ca215490f586e2bca" FOREIGN KEY ("userId") REFERENCES public.users(id);


--
-- Name: battery_status FK_battery_status_powersourceId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.battery_status
    ADD CONSTRAINT "FK_battery_status_powersourceId" FOREIGN KEY ("powersourceId") REFERENCES public.powersources(id);


--
-- Name: notification_settings FK_be017118088b428c9acaa2d2e1984384; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_settings
    ADD CONSTRAINT "FK_be017118088b428c9acaa2d2e1984384" FOREIGN KEY ("typeId") REFERENCES public.notification_types(id);


--
-- Name: notification_settings_locations_categories FK_bffbb1b25c30434eb91ac25f5413eab1; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_settings_locations_categories
    ADD CONSTRAINT "FK_bffbb1b25c30434eb91ac25f5413eab1" FOREIGN KEY ("categoryId") REFERENCES public.notification_categories(id) ON DELETE CASCADE;


--
-- Name: bundle_catalog_items FK_bundle_catalog_items_bundleCatalogId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bundle_catalog_items
    ADD CONSTRAINT "FK_bundle_catalog_items_bundleCatalogId" FOREIGN KEY ("bundleCatalogId") REFERENCES public.bundle_catalog(id);


--
-- Name: bundle_catalog_items FK_bundle_catalog_items_gatewayCatalogId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bundle_catalog_items
    ADD CONSTRAINT "FK_bundle_catalog_items_gatewayCatalogId" FOREIGN KEY ("gatewayCatalogId") REFERENCES public.gateways_catalog(id);


--
-- Name: bundle_catalog_items FK_bundle_catalog_items_powersourceCatalogId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bundle_catalog_items
    ADD CONSTRAINT "FK_bundle_catalog_items_powersourceCatalogId" FOREIGN KEY ("powersourceCatalogId") REFERENCES public.powersources_catalog(id);


--
-- Name: bundle_catalog_items FK_bundle_catalog_items_routerCatalogId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bundle_catalog_items
    ADD CONSTRAINT "FK_bundle_catalog_items_routerCatalogId" FOREIGN KEY ("routerCatalogId") REFERENCES public.routers_catalog(id);


--
-- Name: notification_settings_locations_categories FK_d0d1a990b4164c65beb01839eadc0a7e; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_settings_locations_categories
    ADD CONSTRAINT "FK_d0d1a990b4164c65beb01839eadc0a7e" FOREIGN KEY ("notificationSettingId") REFERENCES public.notification_settings(id) ON DELETE CASCADE;


--
-- Name: locations FK_d412a132c2254290a76183575b39e447; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT "FK_d412a132c2254290a76183575b39e447" FOREIGN KEY ("e911AddressId") REFERENCES public.addresses(id);


--
-- Name: accounts FK_d5c595053ba34930a72d132522123755; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT "FK_d5c595053ba34930a72d132522123755" FOREIGN KEY ("statusId") REFERENCES public.organization_status(id);


--
-- Name: notifications FK_d7857c0e4e514eeb8a33bb759a4b9990; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT "FK_d7857c0e4e514eeb8a33bb759a4b9990" FOREIGN KEY ("categoryId") REFERENCES public.notification_categories(id);


--
-- Name: catalog_media FK_db2c36763ba04fd5d18be3d32fb; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.catalog_media
    ADD CONSTRAINT "FK_db2c36763ba04fd5d18be3d32fb" FOREIGN KEY ("mediaId") REFERENCES public.media(id) ON DELETE CASCADE;


--
-- Name: locations FK_df8cdfd5dd774681b43412e2ab2c70c7; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT "FK_df8cdfd5dd774681b43412e2ab2c70c7" FOREIGN KEY ("primaryContactId") REFERENCES public.contacts(id);


--
-- Name: dids FK_dids_gatewayId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dids
    ADD CONSTRAINT "FK_dids_gatewayId" FOREIGN KEY ("gatewayId") REFERENCES public.gateways(id);


--
-- Name: catalog_media FK_e1298fe510749433d9f54416040; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.catalog_media
    ADD CONSTRAINT "FK_e1298fe510749433d9f54416040" FOREIGN KEY ("catalogId") REFERENCES public.catalog(id) ON DELETE CASCADE;


--
-- Name: accounts FK_e1496dabea319842640e45fb3ed; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT "FK_e1496dabea319842640e45fb3ed" FOREIGN KEY ("parentId") REFERENCES public.accounts(id);


--
-- Name: dids FK_e50bb231c7529b6be27a9620342; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dids
    ADD CONSTRAINT "FK_e50bb231c7529b6be27a9620342" FOREIGN KEY ("serviceStatusId") REFERENCES public.service_status(id);


--
-- Name: sims FK_e55de20175e5b41cd379a6d00e3; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sims
    ADD CONSTRAINT "FK_e55de20175e5b41cd379a6d00e3" FOREIGN KEY ("locationId") REFERENCES public.accounts(id);


--
-- Name: brand_mac_addresses FK_e67d214d1372429193a74d8db3113be4; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.brand_mac_addresses
    ADD CONSTRAINT "FK_e67d214d1372429193a74d8db3113be4" FOREIGN KEY ("brandId") REFERENCES public.brands(id);


--
-- Name: organization_notifications FK_eb5119d4e09a4305b5545b153faa6213; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization_notifications
    ADD CONSTRAINT "FK_eb5119d4e09a4305b5545b153faa6213" FOREIGN KEY ("orgIdOld") REFERENCES public.accounts(id);


--
-- Name: equipment_bundle_items FK_equipment_bundle_items_equipmentBundleId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_bundle_items
    ADD CONSTRAINT "FK_equipment_bundle_items_equipmentBundleId" FOREIGN KEY ("equipmentBundleId") REFERENCES public.equipment_bundles(id);


--
-- Name: equipment_bundle_items FK_equipment_bundle_items_gatewayId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_bundle_items
    ADD CONSTRAINT "FK_equipment_bundle_items_gatewayId" FOREIGN KEY ("gatewayId") REFERENCES public.gateways(id);


--
-- Name: equipment_bundle_items FK_equipment_bundle_items_powersourceId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_bundle_items
    ADD CONSTRAINT "FK_equipment_bundle_items_powersourceId" FOREIGN KEY ("powersourceId") REFERENCES public.powersources(id);


--
-- Name: equipment_bundle_items FK_equipment_bundle_items_routerId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_bundle_items
    ADD CONSTRAINT "FK_equipment_bundle_items_routerId" FOREIGN KEY ("routerId") REFERENCES public.routers(id);


--
-- Name: equipment_bundles FK_equipment_bundles_adminStatusId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_bundles
    ADD CONSTRAINT "FK_equipment_bundles_adminStatusId" FOREIGN KEY ("adminStatusId") REFERENCES public.equipment_admin_status(id);


--
-- Name: equipment_bundles FK_equipment_bundles_bundleCatalogId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_bundles
    ADD CONSTRAINT "FK_equipment_bundles_bundleCatalogId" FOREIGN KEY ("bundleCatalogId") REFERENCES public.bundle_catalog(id);


--
-- Name: equipment_bundles FK_equipment_bundles_locationId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_bundles
    ADD CONSTRAINT "FK_equipment_bundles_locationId" FOREIGN KEY ("locationId") REFERENCES public.accounts(id);


--
-- Name: equipment_bundles FK_equipment_bundles_ownerId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment_bundles
    ADD CONSTRAINT "FK_equipment_bundles_ownerId" FOREIGN KEY ("ownerId") REFERENCES public.equipment_owners(id);


--
-- Name: netcloud FK_equipment_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.netcloud
    ADD CONSTRAINT "FK_equipment_id" FOREIGN KEY ("equipmentId") REFERENCES public.equipment(id);


--
-- Name: gdmsSipServer FK_equipment_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."gdmsSipServer"
    ADD CONSTRAINT "FK_equipment_id" FOREIGN KEY ("equipmentId") REFERENCES public.equipment(id) ON DELETE CASCADE;


--
-- Name: gdmsSipServer FK_gateway_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."gdmsSipServer"
    ADD CONSTRAINT "FK_gateway_id" FOREIGN KEY ("gatewayId") REFERENCES public.gateways(id) ON DELETE CASCADE;


--
-- Name: gateways FK_gateways_adminStatusId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateways
    ADD CONSTRAINT "FK_gateways_adminStatusId" FOREIGN KEY ("adminStatusId") REFERENCES public.equipment_admin_status(id);


--
-- Name: gateways FK_gateways_gatewayCatalogId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateways
    ADD CONSTRAINT "FK_gateways_gatewayCatalogId" FOREIGN KEY ("gatewayCatalogId") REFERENCES public.gateways_catalog(id);


--
-- Name: gateways FK_gateways_operationalStatusId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateways
    ADD CONSTRAINT "FK_gateways_operationalStatusId" FOREIGN KEY ("operationalStatusId") REFERENCES public.equipment_operational_status(id);


--
-- Name: zendesk FK_location_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zendesk
    ADD CONSTRAINT "FK_location_id" FOREIGN KEY ("locationId") REFERENCES public.locations(id);


--
-- Name: organizations FK_organization_address_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT "FK_organization_address_id" FOREIGN KEY ("addressId") REFERENCES public.addresses(id);


--
-- Name: gdmsSite FK_organization_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."gdmsSite"
    ADD CONSTRAINT "FK_organization_id" FOREIGN KEY ("orgIdOld") REFERENCES public.accounts(id);


--
-- Name: zendesk FK_organization_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zendesk
    ADD CONSTRAINT "FK_organization_id" FOREIGN KEY ("organizationId") REFERENCES public.organizations(id);


--
-- Name: organizations FK_organization_logo_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT "FK_organization_logo_id" FOREIGN KEY ("logoId") REFERENCES public.media(id);


--
-- Name: organizations FK_organization_status_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT "FK_organization_status_id" FOREIGN KEY ("statusId") REFERENCES public.organization_status(id);


--
-- Name: powersources FK_powersources_adminStatusId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.powersources
    ADD CONSTRAINT "FK_powersources_adminStatusId" FOREIGN KEY ("adminStatusId") REFERENCES public.equipment_admin_status(id);


--
-- Name: powersources FK_powersources_batteryStatusId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.powersources
    ADD CONSTRAINT "FK_powersources_batteryStatusId" FOREIGN KEY ("batteryStatusId") REFERENCES public.battery_status(id);


--
-- Name: powersources FK_powersources_operationalStatusId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.powersources
    ADD CONSTRAINT "FK_powersources_operationalStatusId" FOREIGN KEY ("operationalStatusId") REFERENCES public.equipment_operational_status(id);


--
-- Name: powersources FK_powersources_powersourceCatalogId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.powersources
    ADD CONSTRAINT "FK_powersources_powersourceCatalogId" FOREIGN KEY ("powersourceCatalogId") REFERENCES public.powersources_catalog(id);


--
-- Name: powersources FK_powersources_routerId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.powersources
    ADD CONSTRAINT "FK_powersources_routerId" FOREIGN KEY ("routerId") REFERENCES public.routers(id);


--
-- Name: netcloud FK_router_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.netcloud
    ADD CONSTRAINT "FK_router_id" FOREIGN KEY ("routerId") REFERENCES public.routers(id);


--
-- Name: routers FK_routers_adminStatusId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routers
    ADD CONSTRAINT "FK_routers_adminStatusId" FOREIGN KEY ("adminStatusId") REFERENCES public.equipment_admin_status(id);


--
-- Name: routers FK_routers_operationalStatusId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routers
    ADD CONSTRAINT "FK_routers_operationalStatusId" FOREIGN KEY ("operationalStatusId") REFERENCES public.equipment_operational_status(id);


--
-- Name: routers FK_routers_routerCatalogId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routers
    ADD CONSTRAINT "FK_routers_routerCatalogId" FOREIGN KEY ("routerCatalogId") REFERENCES public.routers_catalog(id);


--
-- Name: sims FK_sims_routerId; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sims
    ADD CONSTRAINT "FK_sims_routerId" FOREIGN KEY ("routerId") REFERENCES public.routers(id);


--
-- Name: zendesk FK_zendeskType_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zendesk
    ADD CONSTRAINT "FK_zendeskType_id" FOREIGN KEY ("zendeskTypeId") REFERENCES public.zendesk_type(id);


--
-- Name: account_notes account_notes_accountId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account_notes
    ADD CONSTRAINT "account_notes_accountId_fkey" FOREIGN KEY ("accountId") REFERENCES public.accounts(id);


--
-- Name: accounts accounts_divisionId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT "accounts_divisionId_fkey" FOREIGN KEY ("divisionId") REFERENCES public.division(id);


--
-- Name: accounts accounts_organizationId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT "accounts_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES public.organizations(id);


--
-- Name: bundle_catalog_items bundle_catalog_items_associatedRouterId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bundle_catalog_items
    ADD CONSTRAINT "bundle_catalog_items_associatedRouterId_fkey" FOREIGN KEY ("associatedRouterId") REFERENCES public.routers_catalog(id);


--
-- Name: contacts contacts_organizationId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT "contacts_organizationId_fkey" FOREIGN KEY ("orgIdOld") REFERENCES public.accounts(id);


--
-- Name: contacts contacts_organizationId_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT "contacts_organizationId_fkey1" FOREIGN KEY ("organizationId") REFERENCES public.organizations(id);


--
-- Name: dids dids_lineTypeId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dids
    ADD CONSTRAINT "dids_lineTypeId_fkey" FOREIGN KEY ("lineTypeId") REFERENCES public.line_types(id);


--
-- Name: division division_accountId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.division
    ADD CONSTRAINT "division_accountId_fkey" FOREIGN KEY ("accountId") REFERENCES public.accounts(id);


--
-- Name: division division_organizationId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.division
    ADD CONSTRAINT "division_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES public.organizations(id);


--
-- Name: equipment equipment_batteryStatusId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment
    ADD CONSTRAINT "equipment_batteryStatusId_fkey" FOREIGN KEY ("batteryStatusId") REFERENCES public.battery_status(id);


--
-- Name: equipment equipment_parentId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.equipment
    ADD CONSTRAINT "equipment_parentId_fkey" FOREIGN KEY ("parentId") REFERENCES public.equipment(id);


--
-- Name: gateways gateways_bundleId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateways
    ADD CONSTRAINT "gateways_bundleId_fkey" FOREIGN KEY ("bundleId") REFERENCES public.equipment_bundles(id);


--
-- Name: gdmsSite gdmsSite_organizationId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."gdmsSite"
    ADD CONSTRAINT "gdmsSite_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES public.organizations(id);


--
-- Name: location_contacts location_contacts_contactId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.location_contacts
    ADD CONSTRAINT "location_contacts_contactId_fkey" FOREIGN KEY ("contactId") REFERENCES public.contacts(id);


--
-- Name: location_contacts location_contacts_contactTypeId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.location_contacts
    ADD CONSTRAINT "location_contacts_contactTypeId_fkey" FOREIGN KEY ("contactTypeId") REFERENCES public.contact_types(id);


--
-- Name: location_contacts location_contacts_locationId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.location_contacts
    ADD CONSTRAINT "location_contacts_locationId_fkey" FOREIGN KEY ("locationId") REFERENCES public.accounts(id);


--
-- Name: notification_settings notification_settings_organizationId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_settings
    ADD CONSTRAINT "notification_settings_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES public.organizations(id);


--
-- Name: organization_notifications organization_notifications_organizationId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization_notifications
    ADD CONSTRAINT "organization_notifications_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES public.organizations(id);


--
-- Name: organization_to_zoominfo_name organization_to_zoominfo_name_organizationId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization_to_zoominfo_name
    ADD CONSTRAINT "organization_to_zoominfo_name_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES public.organizations(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: organization_users organization_users_organizationId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization_users
    ADD CONSTRAINT "organization_users_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES public.organizations(id);


--
-- Name: organization_users organization_users_userId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization_users
    ADD CONSTRAINT "organization_users_userId_fkey" FOREIGN KEY ("userId") REFERENCES public.users(id);


--
-- Name: powersources powersources_bundleId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.powersources
    ADD CONSTRAINT "powersources_bundleId_fkey" FOREIGN KEY ("bundleId") REFERENCES public.equipment_bundles(id);


--
-- Name: routers routers_bundleId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routers
    ADD CONSTRAINT "routers_bundleId_fkey" FOREIGN KEY ("bundleId") REFERENCES public.equipment_bundles(id);


--
-- Name: battery_status tent_battery_status_equipmentId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.battery_status
    ADD CONSTRAINT "tent_battery_status_equipmentId_fkey" FOREIGN KEY ("equipmentId") REFERENCES public.equipment(id);


--
-- Name: users users_organizationId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT "users_organizationId_fkey" FOREIGN KEY ("organizationId") REFERENCES public.organizations(id);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: rdsadmin
--

REVOKE ALL ON SCHEMA public FROM rdsadmin;
GRANT ALL ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO ms_consultant;


--
-- Name: TABLE account_media; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.account_media TO ms_consultant;


--
-- Name: TABLE account_notes; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.account_notes TO ms_consultant;


--
-- Name: TABLE accounts; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.accounts TO ms_consultant;


--
-- Name: TABLE addresses; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.addresses TO ms_consultant;


--
-- Name: TABLE auth_roles; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.auth_roles TO ms_consultant;


--
-- Name: TABLE auth_roles_auth_roles; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.auth_roles_auth_roles TO ms_consultant;


--
-- Name: TABLE battery_status; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.battery_status TO ms_consultant;


--
-- Name: TABLE carriers; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.carriers TO ms_consultant;


--
-- Name: TABLE catalog; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.catalog TO ms_consultant;


--
-- Name: TABLE catalog_media; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.catalog_media TO ms_consultant;


--
-- Name: TABLE contact_types; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.contact_types TO ms_consultant;


--
-- Name: TABLE contacts; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.contacts TO ms_consultant;


--
-- Name: TABLE dids; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.dids TO ms_consultant;


--
-- Name: TABLE division; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.division TO ms_consultant;


--
-- Name: TABLE equipment; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.equipment TO ms_consultant;


--
-- Name: TABLE equipment_install_status; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.equipment_install_status TO ms_consultant;


--
-- Name: TABLE equipment_owners; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.equipment_owners TO ms_consultant;


--
-- Name: TABLE events; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.events TO ms_consultant;


--
-- Name: TABLE line_types; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.line_types TO ms_consultant;


--
-- Name: TABLE locations; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.locations TO ms_consultant;


--
-- Name: TABLE media; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.media TO ms_consultant;


--
-- Name: TABLE migrations; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.migrations TO ms_consultant;


--
-- Name: TABLE napco_codes; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.napco_codes TO ms_consultant;


--
-- Name: TABLE napco_logs; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.napco_logs TO ms_consultant;


--
-- Name: TABLE network_types; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.network_types TO ms_consultant;


--
-- Name: TABLE service_install_status; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.service_install_status TO ms_consultant;


--
-- Name: TABLE service_status; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.service_status TO ms_consultant;


--
-- Name: TABLE service_types; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.service_types TO ms_consultant;


--
-- Name: TABLE sim_status; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.sim_status TO ms_consultant;


--
-- Name: TABLE sims; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.sims TO ms_consultant;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.users TO ms_consultant;


--
-- Name: TABLE users_auth_roles; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.users_auth_roles TO ms_consultant;


--
-- PostgreSQL database dump complete
--

