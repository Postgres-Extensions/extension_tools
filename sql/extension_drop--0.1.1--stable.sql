/*
 * The install script's create_function doesn't exist here, so the loop below does what it does for every
 * function; the VALUES rows are the same as the arguments of its calls in extension_drop.sql.
 */
DO $do$
DECLARE
  ns oid := (SELECT e.extnamespace FROM pg_catalog.pg_extension e WHERE e.extname = 'extension_drop');
  nsname name := (SELECT n.nspname FROM pg_catalog.pg_namespace n WHERE n.oid = ns);
  ext_schema text := pg_catalog.quote_ident(nsname);
  r record;
  c_clean_args text;
BEGIN
  IF NOT pg_catalog.has_schema_privilege('public', ns, 'USAGE') THEN
    RAISE EXCEPTION 'extension_drop requires PUBLIC to have USAGE on schema %', ext_schema
      USING ERRCODE = 'object_not_in_prerequisite_state'
        , HINT = pg_catalog.format(
          'Run GRANT USAGE ON SCHEMA %s TO PUBLIC (creating the schema first if needed), then retry.'
          , ext_schema
        );
  END IF;

  FOR r IN SELECT * FROM (VALUES
    (
      'extension_drop__sanity_check'
      , 'ignore name DEFAULT NULL'
      , 'name[] LANGUAGE sql STABLE'
      , $fn$
SELECT array(
  SELECT extension_name
    FROM @extension_schema@.extension_drop__commands c
    WHERE NOT EXISTS(SELECT 1 FROM pg_catalog.pg_extension e WHERE e.extname = c.extension_name)
      AND extension_name IS DISTINCT FROM ignore
  )
$fn$
      , $$Returns an array of extensions that have drop commands but do not exist. This array should always be empty!$$
      , NULL
    ),
    (
      'extension_drop__sanity_assert'
      , 'ignore name DEFAULT NULL'
      , 'void LANGUAGE plpgsql STABLE'
      , $fn$
DECLARE
  bad name[] := @extension_schema@.extension_drop__sanity_check(ignore);
BEGIN
  IF pg_catalog.array_length(bad, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'unexpected drop commands' USING ERRCODE = 'XD001'
      , DETAIL = pg_catalog.format(
        '%s not exist: %s'
        , CASE WHEN pg_catalog.array_length(bad, 1) = 1 THEN 'This extension does' ELSE 'These extensions do' END
        , pg_catalog.array_to_string(bad, ', ')
      )
      , HINT = $$This should not happen unless someone manually inserted into "extension_drop__commands" or messed with the "extension_drop" event trigger.
  Use SELECT extension_drop__repair() to fix this.$$;
  END IF;
END
$fn$
      , $$Throws an error if the "extension_drop__commands" table is not in a sane state.$$
      , NULL
    ),
    (
      'extension_drop__repair'
      , ''
      , 'void LANGUAGE sql'
      , $fn$
DELETE FROM @extension_schema@.extension_drop__commands
  WHERE extension_name = ANY( @extension_schema@.extension_drop__sanity_check() )
$fn$
      , 'Repairs the "extension_drop__commands" table. THIS FUNCTION SHOULD NEVER BE NEEDED.'
      , ''
    ),
    (
      'extension_drop__get'
      , $$
  extension_name extension_drop__commands.extension_name%TYPE
$$
      , 'extension_drop__commands STABLE LANGUAGE plpgsql'
      , $fn$
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
$fn$
      , $$Get info about a set of commands to be run when an extension is dropped.$$
      , NULL
    ),
    (
      'extension_drop__add'
      , $$
  extension_name extension_drop__commands.extension_name%TYPE
  , sql extension_drop__commands.sql%TYPE
$$
      , 'void LANGUAGE plpgsql'
      , $fn$
BEGIN
  INSERT INTO @extension_schema@.extension_drop__commands VALUES(extension_name, sql);
  PERFORM @extension_schema@.extension_drop__sanity_assert(NULL::name);
END
$fn$
      , $$Adds a set of commands to be run when an extension is dropped.$$
      , ''
    ),
    (
      'extension_drop__remove'
      , $$
  extension_name extension_drop__commands.extension_name%TYPE
$$
      , 'void LANGUAGE sql'
      , $fn$
DELETE FROM @extension_schema@.extension_drop__commands d
  -- extension_drop__get() runs sanity checks for us
  WHERE d.extension_name = (@extension_schema@.extension_drop__get(extension_name)).extension_name
$fn$
      , $$Remove a set of commands to be run when an extension is dropped.$$
      , ''
    ),
    (
      'extension_drop__update'
      , $$
  extension_name extension_drop__commands.extension_name%TYPE
  , sql extension_drop__commands.sql%TYPE
$$
      , 'void LANGUAGE sql'
      , $fn$
UPDATE @extension_schema@.extension_drop__commands d
  SET sql = extension_drop__update.sql
  -- extension_drop__get() runs sanity checks for us
  WHERE d.extension_name = (@extension_schema@.extension_drop__get(extension_name)).extension_name
$fn$
      , $$Update the set of commands to be run when an extension is dropped.$$
      , ''
    ),
    (
      'extension_drop__registered'
      , $$
  extension_names name[]
$$
      , 'name[] LANGUAGE plpgsql STABLE SECURITY DEFINER'
      , $fn$
DECLARE
  ret name[] := array(
    SELECT c.extension_name FROM @extension_schema@.extension_drop__commands c
      WHERE c.extension_name = ANY(extension_names) ORDER BY 1
  );
BEGIN
  -- With nothing registered the trigger returns without reaching its own sanity assert, so check here.
  IF pg_catalog.array_length(ret, 1) IS NULL THEN
    PERFORM @extension_schema@.extension_drop__sanity_assert(NULL::name);
  END IF;
  RETURN ret;
END
$fn$
      , $$Returns the given extensions that have drop commands, after asserting the table is sane if there are none.$$
      , 'public'
    ),
    (
      'extension_drop__event_trigger'
      , ''
      , 'event_trigger LANGUAGE plpgsql'
      , $fn$
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
  PERFORM @extension_schema@.extension_drop__sanity_assert(NULL::name);
END
$fn$
      , 'Event trigger function that does the actual work for extension_drop.'
      , NULL
    ),
    (
      'extension_drop__usage_guard'
      , ''
      , 'event_trigger LANGUAGE plpgsql'
      , $fn$
DECLARE
  ns oid := (SELECT e.extnamespace FROM pg_catalog.pg_extension e WHERE e.extname = 'extension_drop');
  nsname text;
BEGIN
  -- Not installed any more (e.g. DROP OWNED dropped it): nothing to protect.
  IF ns IS NOT NULL AND NOT pg_catalog.has_schema_privilege('public', ns, 'USAGE') THEN
    nsname := (SELECT pg_catalog.quote_ident(n.nspname) FROM pg_catalog.pg_namespace n WHERE n.oid = ns);
    RAISE EXCEPTION 'PUBLIC lacks USAGE on schema %, which extension_drop requires', nsname
      USING ERRCODE = 'object_not_in_prerequisite_state'
        , DETAIL = pg_catalog.format('State found after %s; that command is rolled back.', tg_tag)
        , HINT = pg_catalog.format('Run GRANT USAGE ON SCHEMA %s TO PUBLIC. extension_drop resolves extension_drop__registered() as whichever role drops an extension, which needs USAGE on the schema.', nsname);
  END IF;
END
$fn$
      , 'Event trigger function that stops PUBLIC losing USAGE on the schema extension_drop is installed in.'
      , NULL
    )
  ) AS v(function_name, args, options, body, comment, grants)
  LOOP
    c_clean_args := cat_tools.routine__parse_arg_types_text(r.args);

    EXECUTE pg_catalog.format($create$
CREATE OR REPLACE FUNCTION %s(
%s
) RETURNS %s SET search_path = pg_catalog, pg_temp AS
%L
$create$
      , r.function_name
      , r.args
      , r.options
      , pg_catalog.replace(
          pg_catalog.replace(r.body, '@extension_schema@', ext_schema)
          , '@extension_schema_literal@', pg_catalog.quote_literal(ext_schema)
        )
    );

    IF r.grants IS NOT NULL THEN
      EXECUTE pg_catalog.format('REVOKE ALL ON FUNCTION %s(%s) FROM public', r.function_name, c_clean_args);
      IF r.grants <> '' THEN
        EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION %s(%s) TO %s', r.function_name, c_clean_args, r.grants);
      END IF;
    END IF;

    EXECUTE pg_catalog.format('COMMENT ON FUNCTION %s(%s) IS %L', r.function_name, c_clean_args, r.comment);
  END LOOP;
END
$do$;

-- ALTER EVENT TRIGGER can't change WHEN
DROP EVENT TRIGGER extension_drop;
CREATE EVENT TRIGGER extension_drop
  ON sql_drop
  WHEN tag IN( 'DROP EXTENSION', 'DROP SCHEMA', 'DROP OWNED' ) -- NOTE! This MUST be IN
  EXECUTE PROCEDURE extension_drop__event_trigger()
;

CREATE EVENT TRIGGER extension_drop_usage_guard
  ON ddl_command_end
  WHEN tag IN( 'REVOKE', 'DROP OWNED' ) -- NOTE! This MUST be IN
  EXECUTE PROCEDURE extension_drop__usage_guard()
;

-- vim: sw=2 ts=2 expandtab
