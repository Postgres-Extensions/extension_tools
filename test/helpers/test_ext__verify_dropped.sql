SELECT hasnt_extension('extension_drop_test', 'Test extension does not exist');
SELECT is_empty(
  $$SELECT * FROM $$ || :'TT'
  , :'TT' || ' is empty'
);
SELECT is_empty(
  format($$SELECT unnest(%I.extension_drop__sanity_check())$$, :'extension_drop_schema')
  , 'No stale registration'
);

-- vi: expandtab sw=2 ts=2
