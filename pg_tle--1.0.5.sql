\/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License").
 * You may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * Updates since v1.0.0
 *    1. pg_tle_feature_info_sql_drop() updated so that it cleans up 
 *       registered features associated with an extension when the 
 *       extension is dropped.
 *    2. install_extension_version_sql() added to allow installing a
 *       specific version of sql files for an extension; control file
 *       must already exist and is not altered.
 *    3. uninstall_extension(name, version) updated to handle uninstalling
 *       a specific version of an extension that was installed with sql
 *       file only. 
 */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_tle" to load this file. \quit

CREATE FUNCTION pgtle.install_extension
(
  name text,
  version text,
  description text,
  ext text,
  requires text[] DEFAULT NULL
)
RETURNS boolean
SET search_path TO 'pgtle'
AS 'MODULE_PATHNAME', 'pg_tle_install_extension'
LANGUAGE C;

CREATE FUNCTION pgtle.install_update_path
(
  name text,
  fromvers text,
  tovers text,
  ext text
)
RETURNS boolean
SET search_path TO 'pgtle'
AS 'MODULE_PATHNAME', 'pg_tle_install_update_path'
LANGUAGE C;

CREATE FUNCTION pgtle.set_default_version
(
  name text,
  version text
)
RETURNS boolean
SET search_path TO 'pgtle'
AS 'MODULE_PATHNAME', 'pg_tle_set_default_version'
LANGUAGE C;

CREATE FUNCTION pgtle.uninstall_extension(extname text)
RETURNS boolean
SET search_path TO 'pgtle'
AS $_pgtleie_$
  DECLARE
    ctrpattern text;
    sqlpattern text;
    searchsql  text;
    dropsql    text;
    pgtlensp    text := 'pgtle';
    func       text;
    existsvar  record;
  BEGIN

    ctrpattern := format('%s%%.control', extname);
    sqlpattern := format('%s%%.sql', extname);
    searchsql := 'SELECT proname FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE proname LIKE $1 AND n.nspname = $2';

    EXECUTE searchsql USING ctrpattern, pgtlensp INTO existsvar;
    IF existsvar IS NULL THEN
      RAISE EXCEPTION 'Extension % does not exist', extname USING ERRCODE = 'no_data_found';
    ELSE
      FOR func IN EXECUTE searchsql USING ctrpattern, pgtlensp LOOP
        dropsql := format('DROP FUNCTION %I()', func);
        EXECUTE dropsql;
      END LOOP;
    END IF;

    EXECUTE searchsql USING sqlpattern, pgtlensp INTO existsvar;
    IF existsvar IS NULL THEN
      RAISE WARNING 'Extension % has an anomaly; control function exists, but no sql commands function exists', extname;
    ELSE
      FOR func IN EXECUTE searchsql USING sqlpattern, pgtlensp LOOP
        dropsql := format('DROP FUNCTION %I()', func);
        EXECUTE dropsql;
      END LOOP;
    END IF;

    RETURN true;
  END;
$_pgtleie_$
LANGUAGE plpgsql STRICT;

CREATE FUNCTION pgtle.uninstall_extension_if_exists(extname text)
RETURNS boolean
SET search_path TO 'pgtle'
AS $_pgtleie_$
BEGIN
  PERFORM pgtle.uninstall_extension(extname);
  RETURN TRUE;
EXCEPTION
  WHEN no_data_found THEN
    RETURN FALSE;
END;
$_pgtleie_$
LANGUAGE plpgsql STRICT;

CREATE FUNCTION pgtle.install_extension_version_sql
(
  name text,
  version text,
  ext text
)
RETURNS boolean
SET search_path TO 'pgtle'
AS 'MODULE_PATHNAME', 'pg_tle_install_extension_version_sql'
LANGUAGE C;

-- uninstall an extension for a specific version
CREATE FUNCTION pgtle.uninstall_extension(extname text, version text)
RETURNS boolean
SET search_path TO 'pgtle'
AS $_pgtleie_$
  DECLARE
    ctrpattern         text;
    sqlpattern         text;
    countverssql       text;
    vers_count         bigint;
    defaultversql      text;
    defaultver         text;
    searchsql          text;
    dropsql            text;
    pgtlensp           text := 'pgtle';
    func_available_vers text := 'available_extension_versions()';
    func_available_ext text := 'available_extensions()';
    func               text;
  BEGIN
    ctrpattern := format('%s%%.control', extname);
    sqlpattern := format('%s--%%%s%%.sql', extname, version);
    countverssql := format('SELECT COUNT(*) FROM %s.%s WHERE name = $1', pgtlensp, func_available_vers);
    defaultversql := format('SELECT default_version FROM %s.%s WHERE name = $1', pgtlensp, func_available_ext);
    searchsql := 'SELECT proname FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE proname LIKE $1 AND n.nspname = $2';

    EXECUTE countverssql USING extname INTO vers_count;
    EXECUTE defaultversql USING extname INTO defaultver;

    IF vers_count > 1 THEN
      -- if multiple versions exist and this is the default version, don't uninstall
      IF version = defaultver THEN
        RAISE EXCEPTION 'Can not uninstall default version of extension %, use set_default_version to update the default to another available version and retry', extname;
      ELSE
        -- remove the specified version sql file function only, don't remove control file function
        FOR func IN EXECUTE searchsql USING sqlpattern, pgtlensp LOOP
          dropsql := format('DROP FUNCTION %I()', func);
          EXECUTE dropsql;
        END LOOP;
      END IF;
    ELSE
      -- check that the specified version matches the only version that exists
      -- if it does then uninstall the extension completely
      -- if it doesn't then don't uninstall anything to avoid accidental uninstall
      IF version = defaultver THEN
        FOR func IN EXECUTE searchsql USING ctrpattern, pgtlensp LOOP
          dropsql := format('DROP FUNCTION %I()', func);
          EXECUTE dropsql;
        END LOOP;
        FOR func IN EXECUTE searchsql USING sqlpattern, pgtlensp LOOP
          dropsql := format('DROP FUNCTION %I()', func);
          EXECUTE dropsql;
        END LOOP;
      ELSE
        RAISE EXCEPTION 'Version % of extension % is not installed and therefore can not be uninstalled', extname, version;
      END IF;
    END IF;
    
    RETURN TRUE;
  END;
$_pgtleie_$
LANGUAGE plpgsql STRICT;

-- uninstall a specific update path
CREATE FUNCTION pgtle.uninstall_update_path(extname text, fromvers text, tovers text)
RETURNS boolean
SET search_path TO 'pgtle'
AS $_pgtleie_$
  DECLARE
    sqlpattern text;
    searchsql  text;
    dropsql    text;
    pgtlensp   text := 'pgtle';
    func       text;
    existsvar  record;
  BEGIN
    sqlpattern := format('%s--%s--%s.sql', extname, fromvers, tovers);
    searchsql := 'SELECT proname FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE proname = $1 AND n.nspname = $2';

    EXECUTE searchsql USING sqlpattern, pgtlensp INTO existsvar;

    IF existsvar IS NULL THEN
      RAISE EXCEPTION 'Extension % does not exist', extname USING ERRCODE = 'no_data_found';
    ELSE
      FOR func IN EXECUTE searchsql USING sqlpattern, pgtlensp LOOP
        dropsql := format('DROP FUNCTION %I()', func);
        EXECUTE dropsql;
      END LOOP;
    END IF;

    RETURN TRUE;
  END;
$_pgtleie_$
LANGUAGE plpgsql STRICT;

CREATE FUNCTION pgtle.uninstall_update_path_if_exists(extname text, fromvers text, tovers text)
RETURNS boolean
SET search_path TO 'pgtle'
AS $_pgtleie_$
BEGIN
  PERFORM pgtle.uninstall_update_path(extname, fromvers, tovers);
  RETURN TRUE;
EXCEPTION
  WHEN no_data_found THEN
    RETURN FALSE;
END;
$_pgtleie_$
LANGUAGE plpgsql STRICT;

CREATE FUNCTION pgtle.extension_update_paths
(
  name name,
  OUT source text,
  OUT target text,
  OUT path text
)
RETURNS SETOF RECORD
AS 'MODULE_PATHNAME', 'pg_tle_extension_update_paths'
LANGUAGE C STABLE STRICT;

CREATE FUNCTION pgtle.available_extensions
(
  OUT name name,
  OUT default_version text,
  OUT comment text
)
RETURNS SETOF RECORD
AS 'MODULE_PATHNAME', 'pg_tle_available_extensions'
LANGUAGE C STABLE STRICT;

CREATE FUNCTION pgtle.available_extension_versions
(
  OUT name name,
  OUT version text,
  OUT superuser boolean,
  OUT trusted boolean,
  OUT relocatable boolean,
  OUT schema name,
  OUT requires name[],
  OUT comment text
)
RETURNS SETOF RECORD
AS 'MODULE_PATHNAME', 'pg_tle_available_extension_versions'
LANGUAGE C STABLE STRICT;

-- Revoke privs from PUBLIC
REVOKE EXECUTE ON FUNCTION pgtle.install_extension
(
  name text,
  version text,
  description text,
  ext text,
  requires text[]
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.install_extension_version_sql
(
  name text,
  version text,
  ext text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.install_update_path
(
  name text,
  fromvers text,
  tovers text,
  ext text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.set_default_version
(
  name text,
  version text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.uninstall_extension
(
  extname text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.uninstall_extension
(
  extname text,
  version text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.uninstall_extension_if_exists
(
  extname text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.uninstall_update_path
(
  extname text,
  fromvers text,
  tovers text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.uninstall_update_path_if_exists
(
  extname text,
  fromvers text,
  tovers text
) FROM PUBLIC;

DO
$_do_$
BEGIN
   IF EXISTS (
      SELECT FROM pg_catalog.pg_roles
      WHERE  rolname = 'pgtle_admin') THEN

      RAISE NOTICE 'Role "pgtle_admin" already exists. Skipping.';
   ELSE
      CREATE ROLE pgtle_admin NOLOGIN;
   END IF;
END
$_do_$;

GRANT USAGE, CREATE ON SCHEMA pgtle TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.install_extension
(
  name text,
  version text,
  description text,
  ext text,
  requires text[]
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.install_extension_version_sql
(
  name text,
  version text,
  ext text
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.install_update_path
(
  name text,
  fromvers text,
  tovers text,
  ext text
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.set_default_version
(
  name text,
  version text
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.uninstall_extension
(
  extname text
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.uninstall_extension
(
  extname text,
  version text
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.uninstall_extension_if_exists
(
  extname text
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.uninstall_update_path
(
  extname text,
  fromvers text,
  tovers text
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.uninstall_update_path_if_exists
(
  extname text,
  fromvers text,
  tovers text
) TO pgtle_admin;

CREATE FUNCTION pgtle.create_shell_type
(
  typenamespace regnamespace,
  typename name
)
RETURNS void
SET search_path TO 'pgtle'
STRICT
AS 'MODULE_PATHNAME', 'pg_tle_create_shell_type'
LANGUAGE C;

CREATE FUNCTION pgtle.create_shell_type_if_not_exists
(
  typenamespace regnamespace,
  typename name
)
RETURNS boolean
SET search_path TO 'pgtle'
STRICT
AS 'MODULE_PATHNAME', 'pg_tle_create_shell_type_if_not_exists'
LANGUAGE C;

CREATE FUNCTION pgtle.create_base_type
(
  typenamespace regnamespace,
  typename name,
  infunc regprocedure,
  outfunc regprocedure,
  internallength int4
)
RETURNS void
SET search_path TO 'pgtle'
STRICT
AS 'MODULE_PATHNAME', 'pg_tle_create_base_type'
LANGUAGE C;

CREATE FUNCTION pgtle.create_base_type_if_not_exists
(
  typenamespace regnamespace,
  typename name,
  infunc regprocedure,
  outfunc regprocedure,
  internallength int4
)
RETURNS boolean
SET search_path TO 'pgtle'
AS $_pgtleie_$
BEGIN
  PERFORM pgtle.create_base_type(typenamespace, typename, infunc, outfunc, internallength);
  RETURN TRUE;
EXCEPTION
  -- only catch the duplicate_object exception, let all other exceptions pass through.
  WHEN duplicate_object THEN
    RETURN FALSE;
END;
$_pgtleie_$
LANGUAGE plpgsql STRICT;

CREATE FUNCTION pgtle.create_operator_func
(
  typenamespace regnamespace,
  typename name,
  opfunc regprocedure
)
RETURNS void
SET search_path TO 'pgtle'
STRICT
AS 'MODULE_PATHNAME', 'pg_tle_create_operator_func'
LANGUAGE C;

CREATE FUNCTION pgtle.create_operator_func_if_not_exists
(
  typenamespace regnamespace,
  typename name,
  opfunc regprocedure
)
RETURNS boolean
SET search_path TO 'pgtle'
AS $_pgtleie_$
BEGIN
  PERFORM pgtle.create_operator_func(typenamespace, typename, opfunc);
  RETURN TRUE;
EXCEPTION
  -- only catch the duplicate_object exception, let all other exceptions pass through.
  WHEN duplicate_object THEN
    RETURN FALSE;
END;
$_pgtleie_$
LANGUAGE plpgsql STRICT;

REVOKE EXECUTE ON FUNCTION pgtle.create_shell_type
(
  typenamespace regnamespace,
  typename name
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.create_shell_type_if_not_exists
(
  typenamespace regnamespace,
  typename name
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.create_base_type
(
  typenamespace regnamespace,
  typename name,
  infunc regprocedure,
  outfunc regprocedure,
  internallength int4
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.create_base_type_if_not_exists
(
  typenamespace regnamespace,
  typename name,
  infunc regprocedure,
  outfunc regprocedure,
  internallength int4
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.create_operator_func
(
  typenamespace regnamespace,
  typename name,
  opfunc regprocedure
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.create_operator_func_if_not_exists
(
  typenamespace regnamespace,
  typename name,
  opfunc regprocedure
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION pgtle.create_shell_type
(
  typenamespace regnamespace,
  typename name
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.create_shell_type_if_not_exists
(
  typenamespace regnamespace,
  typename name
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.create_base_type
(
  typenamespace regnamespace,
  typename name,
  infunc regprocedure,
  outfunc regprocedure,
  internallength int4
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.create_base_type_if_not_exists
(
  typenamespace regnamespace,
  typename name,
  infunc regprocedure,
  outfunc regprocedure,
  internallength int4
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.create_operator_func
(
  typenamespace regnamespace,
  typename name,
  opfunc regprocedure
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.create_operator_func_if_not_exists
(
  typenamespace regnamespace,
  typename name,
  opfunc regprocedure
) TO pgtle_admin;

CREATE TYPE pgtle.pg_tle_features as ENUM ('passcheck');
CREATE TYPE pgtle.password_types as ENUM ('PASSWORD_TYPE_PLAINTEXT', 'PASSWORD_TYPE_MD5', 'PASSWORD_TYPE_SCRAM_SHA_256');

CREATE TABLE pgtle.feature_info(
	feature pgtle.pg_tle_features,
	schema_name text,
	proname text,
	obj_identity text NOT NULL,
  PRIMARY KEY(feature, schema_name, proname));

SELECT pg_catalog.pg_extension_config_dump('pgtle.feature_info', '');

GRANT SELECT on pgtle.feature_info TO PUBLIC;

-- Helper function to register features in the feature_info table
CREATE FUNCTION pgtle.register_feature(proc regproc, feature pgtle.pg_tle_features)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
pg_proc_relid oid;
proc_oid oid;
schema_name text;
nspoid oid;
proname text;
proc_schema_name text;
ident text;

BEGIN
	SELECT oid into nspoid FROM pg_catalog.pg_namespace
	where nspname = 'pg_catalog';

	SELECT oid into pg_proc_relid from pg_catalog.pg_class
	where relname = 'pg_proc' and relnamespace = nspoid;

	SELECT pg_namespace.nspname, pg_proc.oid, pg_proc.proname into proc_schema_name, proc_oid, proname FROM
	pg_catalog.pg_namespace, pg_catalog.pg_proc
	where pg_proc.oid = proc AND pg_proc.pronamespace = pg_namespace.oid;

	SELECT identity into ident FROM pg_catalog.pg_identify_object(pg_proc_relid, proc_oid, 0);

	INSERT INTO pgtle.feature_info VALUES (feature, proc_schema_name, proname, ident);
END;
$$;

-- Helper function to softly fail if we try to register a function that already exists
CREATE FUNCTION pgtle.register_feature_if_not_exists(proc regproc, feature pgtle.pg_tle_features)
RETURNS bool
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pgtle.register_feature(proc, feature);
  RETURN TRUE;
EXCEPTION
  -- only catch the unique violation. let all other exceptions pass through.
  WHEN unique_violation THEN
    RETURN FALSE;
END;
$$;

-- Helper function to delete from table
CREATE FUNCTION pgtle.unregister_feature(proc regproc, feature pgtle.pg_tle_features)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
	pg_proc_relid oid;
	proc_oid oid;
	schema_name text;
	nspoid oid;
	proc_name text;
	proc_schema_name text;
	ident text;
	row_count bigint;
BEGIN
	SELECT oid into nspoid
  FROM pg_catalog.pg_namespace
	WHERE nspname = 'pg_catalog';

	SELECT oid into pg_proc_relid
  FROM pg_catalog.pg_class
	WHERE
		relname = 'pg_proc' AND
		relnamespace = nspoid;

	SELECT
		pg_namespace.nspname,
		pg_proc.oid,
		pg_proc.proname
  INTO
		proc_schema_name,
		proc_oid,
		proc_name
	FROM pg_catalog.pg_namespace, pg_catalog.pg_proc
	WHERE
		pg_proc.oid = proc AND
		pg_proc.pronamespace = pg_namespace.oid;

	DELETE FROM pgtle.feature_info
	WHERE
		feature_info.feature = $2 AND
		feature_info.schema_name = proc_schema_name AND
		feature_info.proname = proc_name;

	GET DIAGNOSTICS row_count = ROW_COUNT;

	IF ROW_COUNT = 0 THEN
    RAISE EXCEPTION 'Could not unregister "%": does not exist.', $1 USING ERRCODE = 'no_data_found';
  END IF;
END;
$$;

-- Helper to softly fail if we try to unregister a function that does not exist
CREATE FUNCTION pgtle.unregister_feature_if_exists(proc regproc, feature pgtle.pg_tle_features)
RETURNS bool
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pgtle.unregister_feature(proc, feature);
  RETURN TRUE;
EXCEPTION
  -- only catch the error that no data was found
  WHEN no_data_found THEN
    RETURN FALSE;
END;
$$;

-- Revoke privs from PUBLIC
REVOKE EXECUTE ON FUNCTION pgtle.register_feature
(
  proc regproc,
  feature pgtle.pg_tle_features
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.register_feature_if_not_exists
(
  proc regproc,
  feature pgtle.pg_tle_features
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.unregister_feature
(
  proc regproc,
  feature pgtle.pg_tle_features
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION pgtle.unregister_feature_if_exists
(
  proc regproc,
  feature pgtle.pg_tle_features
) FROM PUBLIC;

-- Grant privs to pgtle_admin
GRANT EXECUTE ON FUNCTION pgtle.register_feature
(
  proc regproc,
  feature pgtle.pg_tle_features
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.register_feature_if_not_exists
(
  proc regproc,
  feature pgtle.pg_tle_features
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.unregister_feature
(
  proc regproc,
  feature pgtle.pg_tle_features
) TO pgtle_admin;

GRANT EXECUTE ON FUNCTION pgtle.unregister_feature_if_exists
(
  proc regproc,
  feature pgtle.pg_tle_features
) TO pgtle_admin;

-- Prevent function from being dropped if referenced in table
CREATE FUNCTION pgtle.pg_tle_feature_info_sql_drop()
RETURNS event_trigger
LANGUAGE plpgsql
AS $$
DECLARE
obj RECORD;
num_rows int;

BEGIN
	FOR obj IN SELECT * FROM pg_catalog.pg_event_trigger_dropped_objects()

	LOOP
		IF obj.object_type = 'function' THEN
			-- if this is from a "DROP EXTENSION" call, use this to clean up any
			-- remaining registered features associated with this extension
			-- otherwise, continue to pass through
			IF TG_TAG = 'DROP EXTENSION' THEN
				BEGIN
					DELETE FROM pgtle.feature_info
					WHERE obj_identity = obj.object_identity;
				EXCEPTION WHEN insufficient_privilege THEN
					-- do nothing, continue on
				END;
			ELSE
				SELECT count(*) INTO num_rows
				FROM pgtle.feature_info
				WHERE obj_identity = obj.object_identity;

				IF num_rows > 0 then
					RAISE EXCEPTION 'Function is referenced in pgtle.feature_info';
				END IF;
			END IF;
		END IF;
	END LOOP;
END;
$$;

CREATE EVENT TRIGGER pg_tle_event_trigger_for_drop_function
   ON sql_drop
   EXECUTE FUNCTION pgtle.pg_tle_feature_info_sql_drop();

REVOKE ALL ON SCHEMA pgtle FROM PUBLIC;
GRANT USAGE ON SCHEMA pgtle TO PUBLIC;
GRANT INSERT,DELETE ON TABLE pgtle.feature_info TO pgtle_admin;
