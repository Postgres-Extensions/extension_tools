/*
 * Every function is re-created: every body changed, and each one's pinned search_path goes from
 * <schema>, cat_tools, pg_temp to pg_catalog, pg_temp. The calls below are the same as in extension_drop.sql.
 */
DO $do$
DECLARE
  ns oid := (SELECT e.extnamespace FROM pg_catalog.pg_extension e WHERE e.extname = 'extension_drop');
  nsname name := (SELECT n.nspname FROM pg_catalog.pg_namespace n WHERE n.oid = ns);
  ext_schema text := pg_catalog.quote_ident(nsname);
BEGIN
  IF NOT pg_catalog.has_schema_privilege('public', ns, 'USAGE') THEN
    RAISE EXCEPTION 'cannot update extension_drop in schema "%"', pg_catalog.replace(nsname, '"', '""')
      USING ERRCODE = 'object_not_in_prerequisite_state'
        , DETAIL = 'extension_drop requires PUBLIC to have USAGE on the schema it is installed in.'
        , HINT = pg_catalog.format(
          'Run GRANT USAGE ON SCHEMA %s TO PUBLIC (creating the schema first if needed), then retry.'
          , ext_schema
        );
  END IF;
END
$do$;

/*
 * NOTE: All pg_temp objects must be dropped at the end of the script!
 * Otherwise the eventual DROP CASCADE of pg_temp when the session ends will
 * also drop the extension! Instead of risking problems, create our own
 * "temporary" schema instead.
 */
CREATE SCHEMA __extension_drop;

CREATE FUNCTION __extension_drop.exec(
  sql text
) RETURNS void LANGUAGE plpgsql AS $body$
BEGIN
  RAISE DEBUG 'sql = %', sql;
  EXECUTE sql;
END
$body$;

CREATE FUNCTION __extension_drop.create_function(
  function_name text
  , args text
  , options text
  , body text
  , comment text
  , grants text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  c_clean_args text := cat_tools.routine__parse_arg_types_text(args);

  ext_schema text := COALESCE(
    (
      SELECT pg_catalog.quote_ident(n.nspname)
        FROM pg_catalog.pg_extension e JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'extension_drop'
    )
    -- Not running as an extension script (e.g. the build smoke test)
    , pg_catalog.quote_ident(pg_catalog.current_schema())
  );

  /*
   * Every permanent function is pinned to pg_catalog, pg_temp so nothing a caller can create in a schema
   * they control is ever resolved. Bodies refer to our own objects through @extension_schema@ (an
   * identifier) or @extension_schema_literal@ (the same text as a string literal).
   */
  create_template CONSTANT text := $template$
CREATE OR REPLACE FUNCTION %s(
%s
) RETURNS %s SET search_path = pg_catalog, pg_temp AS
%L
$template$
  ;

  revoke_template CONSTANT text := $template$
REVOKE ALL ON FUNCTION %s(
%s
) FROM public;
$template$
  ;

  grant_template CONSTANT text := $template$
GRANT EXECUTE ON FUNCTION %s(
%s
) TO %s;
$template$
  ;

  comment_template CONSTANT text := $template$
COMMENT ON FUNCTION %s(
%s
) IS %L;
$template$
  ;

BEGIN
  PERFORM __extension_drop.exec( format(
      create_template
      , function_name
      , args
      , options
      , pg_catalog.replace(
          pg_catalog.replace(body, '@extension_schema@', ext_schema)
          , '@extension_schema_literal@', pg_catalog.quote_literal(ext_schema)
        )
    ) )
  ;

  IF grants IS NOT NULL THEN
    PERFORM __extension_drop.exec( format(
        revoke_template
        , function_name
        , c_clean_args
      ) )
    ;
    IF grants <> '' THEN
      PERFORM __extension_drop.exec( format(
          grant_template
          , function_name
          , c_clean_args
          , grants
        ) )
      ;
    END IF;
  END IF;

  IF comment IS NOT NULL THEN
    PERFORM __extension_drop.exec( format(
        comment_template
        , function_name
        , c_clean_args
        , comment
      ) )
    ;
  END IF;
END
$body$;

/*
 * ============================================================================
 * WARNING: DEFINER-SAFE CODE ONLY
 *
 * This function runs with its OWNER's rights whenever extension_drop__claim()
 * (SECURITY DEFINER) calls it through extension_drop__sanity_assert().
 * Keep it definer-safe:
 *
 *   - pinned search_path (done by create_function); every reference to our objects goes through
 *     @extension_schema@
 *   - no dynamic SQL, and the only argument is compared against data, never interpolated
 *   - it only reads
 * ============================================================================
 */
SELECT __extension_drop.create_function(
  'extension_drop__sanity_check'
  , 'ignore name DEFAULT NULL'
  , 'name[] LANGUAGE sql STABLE'
  , $body$
SELECT array(
  SELECT extension_name
    FROM @extension_schema@.extension_drop__commands c
    WHERE NOT EXISTS(SELECT 1 FROM pg_extension e WHERE e.extname = c.extension_name)
      AND extension_name IS DISTINCT FROM ignore
  )
$body$
  , $$Returns an array of extensions that have drop commands but do not exist. This array should always be empty!$$
);

/*
 * ============================================================================
 * WARNING: DEFINER-SAFE CODE ONLY
 *
 * This function runs with its OWNER's rights whenever extension_drop__claim()
 * (SECURITY DEFINER) calls it. Keep it definer-safe:
 *
 *   - pinned search_path (done by create_function); every reference to our objects goes through
 *     @extension_schema@
 *   - no dynamic SQL; the only argument reaches sanity_check as a comparison value
 *   - the only text it raises is built from table contents, which are data, never executed
 * ============================================================================
 */
SELECT __extension_drop.create_function(
  'extension_drop__sanity_assert'
  , 'ignore name DEFAULT NULL'
  , 'void LANGUAGE plpgsql STABLE'
  , $body$
DECLARE
  bad name[] := @extension_schema@.extension_drop__sanity_check(ignore);
BEGIN
  IF array_length(bad, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'unexpected drop commands' USING ERRCODE = 'XD001'
      , DETAIL = format(
        '%s not exist: %s'
        , CASE WHEN array_length(bad, 1) = 1 THEN 'This extension does' ELSE 'These extensions do' END
        , array_to_string(bad, ', ')
      )
      , HINT = $$This should not happen unless someone manually inserted into "extension_drop__commands" or messed with the "extension_drop" event trigger.
  Use SELECT extension_drop__repair() to fix this.$$;
  END IF;
END
$body$
  , $$Throws an error if the "extension_drop__commands" table is not in a sane state.$$
);

/*
 * REPAIR
 */
SELECT __extension_drop.create_function(
  'extension_drop__repair'
  , ''
  , 'void LANGUAGE sql'
  , $body$
DELETE FROM @extension_schema@.extension_drop__commands
  WHERE extension_name = ANY( @extension_schema@.extension_drop__sanity_check() )
$body$
  , 'Repairs the "extension_drop__commands" table. THIS FUNCTION SHOULD NEVER BE NEEDED.'
  , '' -- Just revoke all access
);

/*
 * GET
 */
SELECT __extension_drop.create_function(
  'extension_drop__get'
  , $$
  extension_name extension_drop__commands.extension_name%TYPE
$$
  , 'extension_drop__commands STABLE LANGUAGE plpgsql'
  , $body$
DECLARE
  ret @extension_schema@.extension_drop__commands;
BEGIN
  PERFORM @extension_schema@.extension_drop__sanity_assert(NULL::name);
  SELECT INTO STRICT ret
      *
    FROM @extension_schema@.extension_drop__commands d
    WHERE d.extension_name = extension_drop__get.extension_name
  ;

  RETURN ret;

EXCEPTION WHEN no_data_found THEN
  RAISE 'no drop commands for extension "%"', extension_name
    USING errcode = 'no_data_found'
  ;
END
$body$
  , $$Get info about a set of commands to be run when an extension is dropped.$$
);

/*
 * ADD
 */
SELECT __extension_drop.create_function(
  'extension_drop__add'
  , $$
  extension_name extension_drop__commands.extension_name%TYPE
  , sql extension_drop__commands.sql%TYPE
$$
  , 'void LANGUAGE plpgsql'
  , $body$
BEGIN
  INSERT INTO @extension_schema@.extension_drop__commands VALUES(extension_name, sql);
  PERFORM @extension_schema@.extension_drop__sanity_assert(NULL::name);
END
$body$
  , $$Adds a set of commands to be run when an extension is dropped.$$
  , '' -- Just revoke all access
);

/*
 * REMOVE
 */
SELECT __extension_drop.create_function(
  'extension_drop__remove'
  , $$
  extension_name extension_drop__commands.extension_name%TYPE
$$
  , 'void LANGUAGE sql'
  , $body$
DELETE FROM @extension_schema@.extension_drop__commands d
  -- extension_drop__get() runs sanity checks for us
  WHERE d.extension_name = (@extension_schema@.extension_drop__get(extension_name)).extension_name
$body$
  , $$Remove a set of commands to be run when an extension is dropped.$$
  , '' -- Just revoke all access
);

/*
 * UPDATE
 */
SELECT __extension_drop.create_function(
  'extension_drop__update'
  , $$
  extension_name extension_drop__commands.extension_name%TYPE
  , sql extension_drop__commands.sql%TYPE
$$
  , 'void LANGUAGE sql'
  , $body$
UPDATE @extension_schema@.extension_drop__commands d
  SET sql = extension_drop__update.sql
  -- extension_drop__get() runs sanity checks for us
  WHERE d.extension_name = (@extension_schema@.extension_drop__get(extension_name)).extension_name
$body$
  , $$Update the set of commands to be run when an extension is dropped.$$
  , '' -- Just revoke all access
);

/*
 * CLAIM: SECURITY DEFINER so a role that can drop an extension needs no privileges on
 * extension_drop__commands. It only deletes and returns the registrations of extensions the current
 * sql_drop command is dropping (outside a sql_drop trigger pg_event_trigger_dropped_objects() errors, so
 * a direct call deletes nothing), then runs sanity_assert as the owner. It never runs the returned SQL:
 * the event trigger does that as the dropping role.
 */
SELECT __extension_drop.create_function(
  'extension_drop__claim'
  , ''
  , 'TABLE(extension_name name, sql text) LANGUAGE plpgsql SECURITY DEFINER'
  , $body$
BEGIN
  /*
   * Registered SQL needs a deterministic order, and pg_event_trigger_dropped_objects() has none, so sort
   * by name ("C" collation, independent of the database's). Which order doesn't matter: the dropped
   * extensions' objects are already gone. The CTE is needed because RETURNING has no ORDER BY.
   */
  RETURN QUERY
    WITH del AS (
      DELETE FROM @extension_schema@.extension_drop__commands c
        USING pg_event_trigger_dropped_objects() d
        WHERE c.extension_name = d.object_name AND d.object_type = 'extension'
        RETURNING c.extension_name, c.sql
    )
    SELECT del.extension_name, del.sql FROM del ORDER BY del.extension_name COLLATE "C";

  PERFORM @extension_schema@.extension_drop__sanity_assert(NULL::name);
END
$body$
  , $$Deletes and returns the registrations (extension_name, sql) of the extensions being dropped, in extension-name order, after asserting the table is sane. Only works inside the extension_drop event trigger.$$
  , 'public'
);

/*
 * TRIGGER FUNCTION
 */
SELECT __extension_drop.create_function(
  'extension_drop__event_trigger'
  , ''
  , 'event_trigger LANGUAGE plpgsql'
  , $body$
DECLARE
  r record;
BEGIN
  RAISE DEBUG 'extension_drop event trigger entry: tg_event %, tg_tag %', tg_event, tg_tag;

  -- Most drops involve no extension; don't call the claim function (and its assert) for them.
  IF NOT EXISTS (SELECT 1 FROM pg_event_trigger_dropped_objects() WHERE object_type = 'extension') THEN
    RETURN;
  END IF;

  /*
   * Registered SQL runs with path pg_catalog, <our schema>, pg_temp. The pin is restored right after so
   * the rest of this function never sees our schema (the function-exit restore covers an error).
   */
  FOR r IN SELECT * FROM @extension_schema@.extension_drop__claim() LOOP
    RAISE DEBUG E'extension "%" is being dropped; executing SQL:\n%', r.extension_name, r.sql;
    PERFORM set_config('search_path', format('pg_catalog, %s, pg_temp', @extension_schema_literal@), true);
    EXECUTE r.sql;
    -- qualified: registered SQL may have changed search_path; don't unqualify
    PERFORM pg_catalog.set_config('search_path', 'pg_catalog, pg_temp', true);
  END LOOP;
END
$body$
  , 'Event trigger function that does the actual work for extension_drop.'
);

-- ALTER EVENT TRIGGER can't change WHEN
DROP EVENT TRIGGER extension_drop;
CREATE EVENT TRIGGER extension_drop
  ON sql_drop
  -- DROP SCHEMA CASCADE and DROP OWNED BY also drop extensions.
  WHEN tag IN( 'DROP EXTENSION', 'DROP SCHEMA', 'DROP OWNED' ) -- NOTE! This MUST be IN
  EXECUTE PROCEDURE extension_drop__event_trigger()
;

/*
 * USAGE GUARD: the start trigger refuses any REVOKE / DROP OWNED while PUBLIC already lacks USAGE (the
 * only error that gives the GRANT); the end trigger refuses a command that just removed it.
 */
SELECT __extension_drop.create_function(
  'extension_drop__usage_guard'
  , ''
  , 'event_trigger LANGUAGE plpgsql'
  , $body$
DECLARE
  ns oid := (SELECT e.extnamespace FROM pg_extension e WHERE e.extname = 'extension_drop');
  nsname text;
  detail text := 'extension_drop requires PUBLIC to have USAGE on the schema it is installed in. DDL command: ' || tg_tag;
BEGIN
  -- Not installed any more (e.g. DROP OWNED dropped it): nothing to protect.
  IF ns IS NOT NULL AND NOT has_schema_privilege('public', ns, 'USAGE') THEN
    nsname := (SELECT n.nspname FROM pg_namespace n WHERE n.oid = ns);
    IF tg_event = 'ddl_command_start' THEN
      RAISE EXCEPTION 'PUBLIC lacks USAGE on schema "%"', replace(nsname, '"', '""')
        USING ERRCODE = 'object_not_in_prerequisite_state'
          , DETAIL = detail
          , HINT = format('Run GRANT USAGE ON SCHEMA %s TO PUBLIC.', quote_ident(nsname));
    END IF;
    RAISE EXCEPTION 'cannot remove USAGE on schema "%" from PUBLIC', replace(nsname, '"', '""')
      USING ERRCODE = 'object_not_in_prerequisite_state'
        , DETAIL = detail;
  END IF;
END
$body$
  , 'Event trigger function that stops PUBLIC losing USAGE on the schema extension_drop is installed in.'
);

CREATE EVENT TRIGGER extension_drop__usage_guard_start
  ON ddl_command_start
  WHEN tag IN( 'REVOKE', 'DROP OWNED' ) -- NOTE! This MUST be IN
  EXECUTE PROCEDURE extension_drop__usage_guard()
;

CREATE EVENT TRIGGER extension_drop__usage_guard
  ON ddl_command_end
  WHEN tag IN( 'REVOKE', 'DROP OWNED' ) -- NOTE! This MUST be IN
  EXECUTE PROCEDURE extension_drop__usage_guard()
;

/*
 * Drop "temporary" objects
 */
DROP FUNCTION __extension_drop.create_function(
  function_name text
  , args text
  , options text
  , body text
  , comment text
  , grants text
);
DROP FUNCTION __extension_drop.exec(
  sql text
);
DROP SCHEMA __extension_drop;

-- vim: sw=2 ts=2 expandtab
