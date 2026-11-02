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

CREATE FUNCTION __extension_drop.safe_dump(
  relation regclass
  , filter text DEFAULT ''
) RETURNS void LANGUAGE plpgsql AS $body$
BEGIN
  PERFORM pg_catalog.pg_extension_config_dump(relation, filter);
EXCEPTION WHEN feature_not_supported THEN
  NULL;
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
 * Fail now rather than leave an install that can't drop extensions: the event trigger resolves
 * extension_drop__registered() for the dropping role, which needs USAGE on our schema.
 */
DO $do$
DECLARE
  ns oid := COALESCE(
    (SELECT e.extnamespace FROM pg_catalog.pg_extension e WHERE e.extname = 'extension_drop')
    -- Not running as an extension script (e.g. the build smoke test)
    , (SELECT n.oid FROM pg_catalog.pg_namespace n WHERE n.nspname = pg_catalog.current_schema())
  );
  nsname name := (SELECT n.nspname FROM pg_catalog.pg_namespace n WHERE n.oid = ns);
BEGIN
  IF NOT pg_catalog.has_schema_privilege('public', ns, 'USAGE') THEN
    RAISE EXCEPTION 'extension_drop requires PUBLIC to have USAGE on schema %', pg_catalog.quote_ident(nsname)
      USING ERRCODE = 'object_not_in_prerequisite_state'
        , HINT = pg_catalog.format(
          'Run GRANT USAGE ON SCHEMA %s TO PUBLIC (creating the schema first if needed), then retry.'
          , pg_catalog.quote_ident(nsname)
        );
  END IF;
END
$do$;

CREATE TABLE extension_drop__commands(
  extension_name name PRIMARY KEY
  , sql text NOT NULL
);
SELECT __extension_drop.safe_dump('extension_drop__commands', '');

/*
 * XD001 text, shared by every function that raises it
 */
SELECT __extension_drop.create_function(
  'extension_drop__sanity_error'
  , 'bad name[]'
  , 'TABLE(message text, detail text, hint text) LANGUAGE sql STABLE'
  , $body$
SELECT 'unexpected drop commands'::text
  , pg_catalog.format(
    '%s not exist: %s'
    , CASE WHEN pg_catalog.array_length(bad, 1) = 1 THEN 'This extension does' ELSE 'These extensions do' END
    , pg_catalog.array_to_string(bad, ', ')
  )
  , $$This should not happen unless someone manually inserted into "extension_drop__commands" or messed with the "extension_drop" event trigger.
  Use SELECT extension_drop__repair() to fix this.$$
$body$
  , $$Returns the message, DETAIL and HINT of the XD001 error raised when the given extensions have drop commands but do not exist.$$
);

SELECT __extension_drop.create_function(
  'extension_drop__sanity_check'
  , 'ignore name DEFAULT NULL'
  , 'name[] LANGUAGE sql STABLE'
  , $body$
SELECT array(
  SELECT extension_name
    FROM @extension_schema@.extension_drop__commands c
    WHERE NOT EXISTS(SELECT 1 FROM pg_catalog.pg_extension e WHERE e.extname = c.extension_name)
      AND extension_name IS DISTINCT FROM ignore
  )
$body$
  , $$Returns an array of extensions that have drop commands but do not exist. This array should always be empty!$$
);

SELECT __extension_drop.create_function(
  'extension_drop__sanity_assert'
  , 'ignore name DEFAULT NULL'
  , 'void LANGUAGE plpgsql STABLE'
  , $body$
DECLARE
  bad name[] := @extension_schema@.extension_drop__sanity_check(ignore);
  err record;
BEGIN
  IF pg_catalog.array_length(bad, 1) IS NOT NULL THEN
    SELECT e.message, e.detail, e.hint INTO err FROM @extension_schema@.extension_drop__sanity_error(bad) e;
    RAISE EXCEPTION '%', err.message USING ERRCODE = 'XD001', DETAIL = err.detail, HINT = err.hint;
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
  PERFORM @extension_schema@.extension_drop__sanity_assert();
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
  PERFORM @extension_schema@.extension_drop__sanity_assert();
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
 * REGISTERED: SECURITY DEFINER so the trigger can tell whether a dropped extension is registered without
 * the caller needing table access; reads only, never runs registered SQL.
 */
SELECT __extension_drop.create_function(
  'extension_drop__registered'
  , $$
  extension_names name[]
$$
  , 'name[] LANGUAGE plpgsql STABLE SECURITY DEFINER'
  , $body$
DECLARE
  ret name[] := array(
    SELECT c.extension_name FROM @extension_schema@.extension_drop__commands c
      WHERE c.extension_name = ANY(extension_names) ORDER BY 1
  );
  bad name[];
  err record;
BEGIN
  -- With nothing registered the trigger returns without reaching its own sanity assert, so check here.
  IF pg_catalog.array_length(ret, 1) IS NULL THEN
    bad := array(
      SELECT c.extension_name FROM @extension_schema@.extension_drop__commands c
        WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension e WHERE e.extname = c.extension_name)
    );
    IF pg_catalog.array_length(bad, 1) IS NOT NULL THEN
      SELECT e.message, e.detail, e.hint INTO err FROM @extension_schema@.extension_drop__sanity_error(bad) e;
      RAISE EXCEPTION '%', err.message USING ERRCODE = 'XD001', DETAIL = err.detail, HINT = err.hint;
    END IF;
  END IF;
  RETURN ret;
END
$body$
  , $$Returns the given extensions that have drop commands, after asserting the table is sane if there are none.$$
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
  t record;
  dropping text;
  dropped name[];
  registered name[];
  names text[];
  cmds text[];
  i int;
  msg text;
BEGIN
  RAISE DEBUG 'extension_drop event trigger entry: tg_event %, tg_tag %', tg_event, tg_tag;

  -- Most drops involve no extension; don't touch our table (or assert) for them.
  SELECT pg_catalog.string_agg(
          pg_catalog.format('"%s"', pg_catalog.replace(object_name, '"', '""')), ', ' ORDER BY object_name)
      , pg_catalog.array_agg(object_name::name ORDER BY object_name)
    INTO dropping, dropped
    FROM pg_catalog.pg_event_trigger_dropped_objects()
    WHERE object_type = 'extension';
  IF dropping IS NULL THEN
    RETURN;
  END IF;

  /*
   * Callers without table access can still drop unregistered extensions. If the helper isn't executable,
   * fall through to the DELETE below for its clearer error.
   */
  BEGIN
    registered := @extension_schema@.extension_drop__registered(dropped);
  EXCEPTION WHEN insufficient_privilege THEN
    registered := NULL;
  END;
  IF registered IS NOT NULL AND pg_catalog.array_length(registered, 1) IS NULL THEN
    RETURN;
  END IF;

  /*
   * One statement touches the table, so a privilege error here is ours; registered SQL runs after the
   * handler so its own errors pass through untouched.
   */
  BEGIN
    WITH del AS (
      DELETE FROM @extension_schema@.extension_drop__commands c
        USING pg_catalog.pg_event_trigger_dropped_objects() d
        WHERE c.extension_name = d.object_name AND d.object_type = 'extension'
        RETURNING c.extension_name, c.sql
    )
    SELECT pg_catalog.array_agg(extension_name), pg_catalog.array_agg(sql) INTO names, cmds FROM del;
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT;

    -- Names are always double-quoted (embedded quotes doubled) in the primary message.
    SELECT o.owner
        , pg_catalog.format('%I.%I', n.nspname, c.relname) AS qname
        , (SELECT pg_catalog.array_agg(pg_catalog.format('"%s"', pg_catalog.replace(u.x, '"', '""')) ORDER BY u.ord)
            FROM pg_catalog.unnest(ARRAY[n.nspname::text, c.relname::text, o.owner::text]) WITH ORDINALITY u(x, ord)
          ) AS dq -- schema, table, owner
      INTO t
      FROM pg_catalog.pg_extension e
        JOIN pg_catalog.pg_class c
          ON c.relnamespace = e.extnamespace AND c.relname = 'extension_drop__commands'
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN LATERAL (SELECT pg_catalog.pg_get_userbyid(c.relowner) AS owner) o
      WHERE e.extname = 'extension_drop';
    IF NOT FOUND THEN
      RAISE;
    END IF;

    RAISE EXCEPTION 'permission denied for table %.% (owned by role %), which extension_drop needs to drop extension(s) %'
        , t.dq[1], t.dq[2], t.dq[3], dropping
      USING ERRCODE = 'insufficient_privilege'
        , DETAIL = msg
        , HINT = pg_catalog.format(
            'Run the drop as role %s or a superuser, or grant SELECT, DELETE on %s to the current role.'
            , pg_catalog.quote_ident(t.owner), t.qname);
  END;

  /*
   * Registered SQL runs with path pg_catalog, <our schema>, pg_temp. The pin is restored right after so
   * the rest of this function never sees our schema (the function-exit restore covers an error).
   */
  FOR i IN 1 .. COALESCE(pg_catalog.array_length(cmds, 1), 0) LOOP
    RAISE DEBUG E'extension "%" is being dropped; executing SQL:\n%', names[i], cmds[i];
    PERFORM pg_catalog.set_config('search_path', pg_catalog.format('pg_catalog, %s, pg_temp', @extension_schema_literal@), true);
    EXECUTE cmds[i];
    PERFORM pg_catalog.set_config('search_path', 'pg_catalog, pg_temp', true);
  END LOOP;

  /*
   * Need to do this after the fact since the extensions being dropped have
   * already been removed from the catalog by the time this function is called.
   */
  PERFORM @extension_schema@.extension_drop__sanity_assert();
END
$body$
  , 'Event trigger function that does the actual work for extension_drop.'
);

CREATE EVENT TRIGGER extension_drop
  ON sql_drop
  -- DROP SCHEMA CASCADE and DROP OWNED BY also drop extensions.
  WHEN tag IN( 'DROP EXTENSION', 'DROP SCHEMA', 'DROP OWNED' ) -- NOTE! This MUST be IN
  EXECUTE PROCEDURE extension_drop__event_trigger()
;

/*
 * REVOKE GUARD
 */
SELECT __extension_drop.create_function(
  'extension_drop__usage_guard'
  , ''
  , 'event_trigger LANGUAGE plpgsql'
  , $body$
DECLARE
  ns oid := (SELECT e.extnamespace FROM pg_catalog.pg_extension e WHERE e.extname = 'extension_drop');
  nsname text;
BEGIN
  -- Not installed any more (e.g. DROP OWNED dropped it): nothing to protect.
  IF ns IS NOT NULL AND NOT pg_catalog.has_schema_privilege('public', ns, 'USAGE') THEN
    nsname := (SELECT pg_catalog.quote_ident(n.nspname) FROM pg_catalog.pg_namespace n WHERE n.oid = ns);
    RAISE EXCEPTION 'PUBLIC lacks USAGE on schema %, which extension_drop requires', nsname
      USING ERRCODE = 'object_not_in_prerequisite_state'
        , DETAIL = pg_catalog.format('Checked after %s.', tg_tag)
        , HINT = pg_catalog.format('Run GRANT USAGE ON SCHEMA %s TO PUBLIC. extension_drop resolves extension_drop__registered() as whichever role drops an extension, which needs USAGE on the schema.', nsname);
  END IF;
END
$body$
  , 'Event trigger function that stops PUBLIC losing USAGE on the schema extension_drop is installed in.'
);

CREATE EVENT TRIGGER extension_drop_usage_guard
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
DROP FUNCTION __extension_drop.safe_dump(
  relation regclass
  , text
);
DROP FUNCTION __extension_drop.exec(
  sql text
);
DROP SCHEMA __extension_drop;

-- vim: sw=2 ts=2 expandtab
