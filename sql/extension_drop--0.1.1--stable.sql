/*
 * Update path from 0.1.1 to `stable` (this repo's current in-development
 * source).
 *
 * The only actual behavioral delta between the two is the
 * extension_drop__event_trigger() function body gaining one entry-point
 * RAISE DEBUG line. That's the one change here.
 *
 * Two other differences between 0.1.1 and `stable` are deliberately NOT
 * replayed here, because neither one changes anything about the objects
 * this extension leaves behind after install completes:
 *   - The client_min_messages save/restore HISTORY.asc's `stable` section
 *     documents removing: that code only ever ran inside the install
 *     script's own session, saving/restoring a GUC and dropping its own
 *     temp table before the script finished -- nothing it did was ever part
 *     of the extension's persisted state, so an already-installed 0.1.1 has
 *     nothing left to clean up.
 *   - cat_tools.function__arg_types_text() being renamed to
 *     cat_tools.routine__parse_arg_types_text(): that call only happens
 *     inside the CREATE EXTENSION script's internal __extension_drop.create_function()
 *     builder, transiently, to compute the argument list text for the
 *     REVOKE/GRANT statements it executes immediately -- it's never stored
 *     in any persisted function body. (cat_tools 0.3.0 also keeps the old
 *     name as a deprecated wrapper, so a fresh `CREATE EXTENSION
 *     extension_drop VERSION '0.1.1'` still works today for testing this
 *     very update path.)
 */
CREATE OR REPLACE FUNCTION extension_drop__event_trigger(
) RETURNS event_trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS
$body$
DECLARE
  r extension_drop__commands;
BEGIN
  RAISE DEBUG 'extension_drop event trigger entry: tg_event %, tg_tag %', tg_event, tg_tag;
  FOR r IN
    SELECT c.*
      FROM extension_drop__commands c
        JOIN pg_event_trigger_dropped_objects() d
          ON c.extension_name = d.object_name
            AND d.object_type = 'extension'
  LOOP
    RAISE DEBUG E'extension "%" is being dropped; executing SQL:\n%', r.extension_name, r.sql;
    EXECUTE r.sql;
    DELETE FROM extension_drop__commands WHERE extension_name = r.extension_name;
  END LOOP;

  /*
   * Need to do this after the fact since the extensions being dropped have
   * already been removed from the catalog by the time this function is called.
   */
  PERFORM extension_drop__sanity_assert();
END
$body$;

-- vim: sw=2 ts=2 expandtab
