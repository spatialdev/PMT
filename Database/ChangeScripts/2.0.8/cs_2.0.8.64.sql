/******************************************************************
Change Script 2.0.8.64
1. pmt_edit_participation_taxonomy - update function to all multiple
classification_ids and entity_ids
******************************************************************/
INSERT INTO version(version, iteration, changeset) VALUES (2.0, 8, 64);
-- select * from version order by changeset desc;

/******************************************************************
   TESTING
   
 57 - reader (read)
 54 - editor (read,create,update)
 55 - super (read,create,update,delete)

 UPDATE "user" SET organization_id = 27 where user_id = 54;
 project_ids: 662,665,661,463,664,663,666
 participation_ids: 6003,6004,6005,6014,6063,6421,6034
 Organisation Role taxonomy: 494,495,496,497
 Organisation Type taxonomy: 498,499,500,501,502,503,504,505,506
 
-- reader (expected return: false)
select * from pmt_edit_participation_taxonomy(57,'6005','496','add') -- pass
select * from pmt_edit_participation_taxonomy(57,'6005','496','delete') -- pass
select * from pmt_edit_participation_taxonomy(57,'6005','496','replace') -- pass

-- editor (expected return: true)
select * from pmt_edit_participation_taxonomy(54,'6003,6004,6005','495,498','add') -- pass
select * from pmt_edit_participation_taxonomy(54,'6005','495,498,999999,500','delete') -- pass
select * from pmt_edit_participation_taxonomy(54,'6003,6004','494,496','replace') -- pass
select * from pmt_edit_participation_taxonomy(54,'6003,6004,6005','498','delete') -- pass

-- super (expected return: true)
select * from pmt_edit_participation_taxonomy(55,'6003,6004,6005','495,500','replace') -- pass
select * from pmt_edit_participation_taxonomy(55,'6005','496,498,999999','add') -- pass
select * from pmt_edit_participation_taxonomy(55,'6003,6004','494,496','replace') -- pass
select * from pmt_edit_participation_taxonomy(55,'6003,6004,6005','498,500','delete') -- pass

select * from pmt_edit_participation_taxonomy(55,'6003,6004,6005','494,496','replace') -- original data

select pt.participation_id, pt.classification_id, tc.taxonomy, tc.classification 
from participation_taxonomy pt
join taxonomy_classifications tc
on pt.classification_id = tc.classification_id
where pt.participation_id in (6003,6004,6005)
order by pt.participation_id

select classification_id, classification, taxonomy from taxonomy_classifications where taxonomy  in ('Organisation Role', 'Organisation Type')
select participation_id from participation where active = true and project_id in (463,661,662,663,664,665,666)
select distinct taxonomy from participation_taxonomy at join taxonomy_classifications tc on at.classification_id = tc.classification_id 
******************************************************************/

-- Drop old function (Don't run on databases with active applications)
DROP FUNCTION IF EXISTS pmt_edit_participation_taxonomy(integer, integer, integer, pmt_edit_action)  CASCADE;

-- New Drop Statement for updated function
DROP FUNCTION IF EXISTS pmt_edit_participation_taxonomy(integer, character varying, character varying, pmt_edit_action)  CASCADE;

/******************************************************************
   pmt_edit_participation_taxonomy
******************************************************************/
CREATE OR REPLACE FUNCTION pmt_edit_participation_taxonomy(user_id integer, participation_ids character varying, classification_ids character varying, edit_action pmt_edit_action) RETURNS BOOLEAN AS 
$$
DECLARE
  valid_classification_ids integer[];	-- valid classification_ids from parameter
  valid_participation_ids integer[];    	-- valid participation_ids from parameter
  pp_id integer;			-- participation_id
  c_id integer;				-- classification_id
  p_id integer;				-- project_id
  pt_id integer;			-- participation_taxonomy participation_id
  tc record;				-- taxonomy_classifications record			-- 
  error_msg1 text;
  error_msg2 text;
  error_msg3 text; 
BEGIN	

  -- first and second parameters are required
  IF ($1 IS NOT NULL) AND ($2 is not null AND $2 <> '') AND ($3 is not null AND $3 <> '') THEN
  
    -- validate participation_ids
    SELECT INTO valid_participation_ids * FROM pmt_validate_participations($2);
    -- validate classification_ids
    SELECT INTO valid_classification_ids * FROM pmt_validate_classifications($3);
    
     -- must provide a min of one valid participation_id to continue
    IF valid_participation_ids IS NULL THEN
      RAISE NOTICE 'Error: Must provide a valid participation_id.';
      RETURN false;
    END IF;
        
    -- must provide a valid classification_id to continue
    IF valid_classification_ids IS NULL THEN
      RAISE NOTICE 'Error: Must provide a valid classification_id.';
      RETURN false;
    END IF;

    -- loop through sets of valid classification_ids by taxonomy
    FOR tc IN EXECUTE 'SELECT taxonomy_id::integer, array_agg(classification_id)::integer[] AS classification_id FROM taxonomy_classifications  tc ' ||
		'WHERE classification_id = ANY(ARRAY['|| array_to_string(valid_classification_ids, ',') || ']) GROUP BY taxonomy_id ORDER BY taxonomy_id ' LOOP     
          
      -- operations based on edit_action
      CASE $4
        WHEN 'delete' THEN
          FOREACH pp_id IN ARRAY valid_participation_ids LOOP 
            SELECT INTO p_id project_id from participation where participation_id = pp_id;
            -- validate users authority to perform an update action on this participation record (use update permission for delete of taxonomy relationships)
            IF (SELECT * FROM pmt_validate_user_authority($1, p_id, 'update')) THEN 
              EXECUTE 'DELETE FROM participation_taxonomy WHERE participation_id ='|| pp_id ||' AND classification_id = ANY(ARRAY['|| array_to_string(tc.classification_id, ',') ||']) AND field = ''participation_id'''; 
              RAISE NOTICE 'Delete Record: %', 'Remove association to classification_id(s) ('|| array_to_string(tc.classification_id, ',') ||') for participation_id ('|| pp_id ||')';
            ELSE
              RAISE NOTICE 'Error: The requested edit action requires the user to have UPDATE rights to this project: %', p_id;
	      RETURN FALSE; 
	    END IF; 	   
          END LOOP;
        WHEN 'replace' THEN
          FOREACH pp_id IN ARRAY valid_participation_ids LOOP 
            SELECT INTO p_id project_id from participation where participation_id = pp_id;
            --validate user authority to perform a create action on this request
            IF (SELECT * FROM pmt_validate_user_authority($1, p_id, 'update')) AND (SELECT * FROM pmt_validate_user_authority($1, p_id, 'create')) THEN
              -- remove all classifications for given taxonomy 
              EXECUTE 'DELETE FROM participation_taxonomy WHERE participation_id ='|| pp_id ||' AND classification_id in ' ||
                      '(SELECT classification_id FROM taxonomy_classifications WHERE taxonomy_id = '|| tc.taxonomy_id||') AND field = ''participation_id''';
              RAISE NOTICE 'Delete Record: %', 'Remove association to taxonomy_id ('|| tc.taxonomy_id ||') for participation_id ('|| pp_id ||')';
              -- insert all classification_ids for this taxonomy
	      EXECUTE 'INSERT INTO participation_taxonomy(participation_id, classification_id, field) SELECT '|| pp_id ||', classification_id, ''participation_id'' FROM ' ||
		      'classification WHERE classification_id IN (' || array_to_string(tc.classification_id, ',') || ')'; 
              RAISE NOTICE 'Add Record: %', 'participation_id ('|| pp_id ||') is now associated to classification_ids ('|| array_to_string(tc.classification_id, ',') ||').';
            ELSE
              RAISE NOTICE 'Error: The requested edit action requires the user to have UPDATE and CREATE rights to this project: %', p_id;
              RETURN FALSE;
            END IF;  
          END LOOP;
        -- add (DEFAULT)
        ELSE
          FOREACH pp_id IN ARRAY valid_participation_ids LOOP 
            SELECT INTO p_id project_id from participation where participation_id = pp_id;
            -- validate users authority to perform a create action on this project
            IF (SELECT * FROM pmt_validate_user_authority($1, p_id, 'create')) THEN 
              FOREACH c_id IN ARRAY tc.classification_id LOOP
                -- check to see if this classification is already assoicated to the participation record
                SELECT INTO pt_id participation_id FROM participation_taxonomy as lt WHERE lt.participation_id = pp_id AND lt.classification_id = c_id LIMIT 1;
                IF pt_id IS NULL THEN
                  EXECUTE 'INSERT INTO participation_taxonomy(participation_id, classification_id, field) VALUES ('|| pp_id ||', '|| c_id ||', ''participation_id'')';
                  RAISE NOTICE 'Add Record: %', 'participation_id ('|| pp_id ||') is now associated to classification_id ('|| c_id ||').'; 
                ELSE
                  RAISE NOTICE'Add Record: %', 'This participation_id ('|| pp_id ||') already has an association to this classification_id ('|| c_id ||').';                
                END IF;
              END LOOP;
            ELSE
              RAISE NOTICE 'Error: The requested edit action requires the user to have CREATE rights to this project: %', p_id;
	      RETURN FALSE; 
	    END IF;
          END LOOP;
        END CASE;
    END LOOP;    
    -- return successful execution
    RETURN true;
  -- first three parameters are required 
  ELSE
   RAISE NOTICE 'Error: Must provide user_id, project_ids and classification_ids parameters.';
    RETURN false;
  END IF; 	

  EXCEPTION WHEN others THEN
   GET STACKED DIAGNOSTICS error_msg1 = MESSAGE_TEXT,
		  error_msg2 = PG_EXCEPTION_DETAIL,
		  error_msg3 = PG_EXCEPTION_HINT;
                          
  RAISE NOTICE 'Error: %', error_msg1;                          
  RETURN FALSE; 
END;$$ LANGUAGE plpgsql;

-- update permissions
GRANT USAGE ON SCHEMA public TO pmt_read;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pmt_read;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO pmt_read;
GRANT USAGE ON SCHEMA public TO pmt_write;
GRANT SELECT,INSERT ON ALL TABLES IN SCHEMA public TO pmt_write;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO pmt_write;