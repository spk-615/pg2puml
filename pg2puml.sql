create or replace function pg2puml(
  variadic keytabs text[] default '{}'::text[],
       out puml text
) returns text as
$$
select concat(
  '@startuml',
  E'\n',
  'skinparam linetype ortho', -- orthogonal connection lines
  E'\n',
  (select string_agg(entity.def, E'\n\n')
     from (select concat_ws(E'\n',
                            'entity ' || col.table_schema || '.' || col.table_name || ' {',
                            string_agg (concat_ws (' ',
                                                   '*',
                                                   concat(col.column_name, ': ', col.data_type),
                                                   case when 'FOREIGN KEY' = any(cons.keys) then '<FK>'
                                                        else null
                                                    end
                                                  ),
                                        E'\n')
                                filter (where 'PRIMARY KEY' = any(cons.keys)),
                            '--',
                            string_agg (concat_ws (' ',
                                                   case when col.is_nullable::boolean then ' '
                                                        else '*'
                                                    end, 
                                                   col.column_name, ': ' || col.data_type,
                                                   case when 'FOREIGN KEY' = any(cons.keys) then '<FK>'
                                                   else null
                                                    end
                                                  ),
                                         E'\n'
                                         order by ordinal_position
                                        )
                                filter (where 'PRIMARY KEY' <> all(coalesce(cons.keys, '{}'::text[]))),
                            E'}\n'
                           )
             from information_schema.columns col
             join information_schema.tables tab
               on tab.table_schema = col.table_schema
              and tab.table_name = col.table_name
              and tab.table_type = 'BASE TABLE'
             left join lateral (select array_agg(constraint_type::text)
                                  from information_schema.table_constraints tco
                                  join information_schema.key_column_usage ccu using (constraint_schema, table_name, constraint_name)
                                 where tco.constraint_type in ('PRIMARY KEY', 'FOREIGN KEY')
                                   and tco.constraint_schema = col.table_schema
                                   and tco.table_name = col.table_name
                                   and ccu.column_name = col.column_name
                                 group by tco.constraint_schema,
                                          tco.table_name,
                                          ccu.column_name) cons(keys)
               on true                   
            where (cardinality(keytabs) = 0 
               or col.table_schema || '.' || col.table_name = any(keytabs))
            group by col.table_schema,
                     col.table_name
            order by col.table_schema,
                     col.table_name
          ) entity(def)
  ),
  E'\n\n',
  (select string_agg(concat(fk.key_schema, '.', fk.key_table,
                             case when key_unique
                                  then ' |o'
                                  else ' }o'
                              end, 
                             case when key_not_null
                                  then '--|| '
                                  else '..o| '
                              end,
                             fk.ref_schema, '.', fk.ref_table),
                      E'\n')
                             
     from ( select tco.constraint_name,
                   key_.table_schema as key_schema,
                   key_.table_name as key_table,
                   key_.columns as key_columns,
                   key_.not_null as key_not_null,
                   (select exists (select
                                     from information_schema.table_constraints tco2
                                     join information_schema.key_column_usage kcu
                                       on kcu.constraint_name = tco2.constraint_name
                                      and kcu.table_schema = tco2.constraint_schema
                                    where tco2.constraint_type in ('UNIQUE', 'PRIMARY KEY')
                                      and tco2.constraint_schema = key_.table_schema
                                      and tco2.table_name = key_.table_name
                                    group by tco2.constraint_schema, tco2.constraint_name
                                   having array_agg(column_name::text) @> key_.columns
                                      and key_.columns @> array_agg(column_name::text)
                                  )
                   ) as key_unique,
                   ref_.table_schema as ref_schema,
                   ref_.table_name as ref_table,
                   ref_.columns
              from information_schema.table_constraints tco
              join (select kcu.constraint_name,
                           kco.table_schema,
                           kco.table_name,
                           array_agg(kco.column_name::text),
                           bool_and(not (is_nullable::boolean))
                      from information_schema.key_column_usage kcu
                      join information_schema.columns kco
                        on kco.table_schema = kcu.table_schema
                       and kco.table_name = kcu.table_name
                       and kco.column_name = kcu.column_name
                     group by constraint_name,
                              kco.table_schema,
                              kco.table_name) key_(constraint_name,
                                                   table_schema,
                                                   table_name,
                                                   columns,
                                                   not_null)
                on key_.table_schema = tco.constraint_schema
               and key_.constraint_name = tco.constraint_name
          
              join (select ccu.constraint_schema,
                           ccu.constraint_name,
                           cco.table_schema,
                           cco.table_name,
                           array_agg(cco.column_name::text),
                           bool_and(not (is_nullable::boolean))
                      from information_schema.constraint_column_usage ccu
                      join information_schema.columns cco
                        on cco.table_schema = ccu.table_schema
                       and cco.table_name = ccu.table_name
                       and cco.column_name = ccu.column_name
                     group by ccu.constraint_schema,
                              ccu.constraint_name,
                              cco.table_schema,
                              cco.table_name) ref_(constraint_schema,
                                                   constraint_name,
                                                   table_schema,
                                                   table_name,
                                                   columns,
                                                   not_null)
                on ref_.constraint_schema = tco.constraint_schema
               and ref_.constraint_name = tco.constraint_name
             where constraint_type = 'FOREIGN KEY'
               and (cardinality(keytabs) = 0 
                or key_.table_schema || '.' || key_.table_name = any(keytabs))
             order by constraint_name
            ) fk 
  ),
  E'\n',
  '@enduml'
) as puml;          
$$ language sql strict stable;

