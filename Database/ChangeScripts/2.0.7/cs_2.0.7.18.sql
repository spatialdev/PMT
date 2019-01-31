/******************************************************************
Change Script 2.0.7.18 - Consolidated.
1. pmt_activity_listview -  adding date parameters.
2. pmt_activity_listview_ct -  adding date parameters.
******************************************************************/
INSERT INTO config(version, iteration, changeset) VALUES (2.0, 7, 18);
-- select * from config order by changeset desc;

-- drop statements (old)
DROP FUNCTION IF EXISTS pmt_activity_listview(integer, character varying, character varying, character varying, text, integer, integer) CASCADE;
DROP FUNCTION IF EXISTS pmt_activity_listview_ct(character varying, character varying, character varying) CASCADE;

-- drop statements (new)
DROP FUNCTION IF EXISTS pmt_activity_listview(integer, character varying, character varying, character varying, date, date, text, integer, integer) CASCADE;
DROP FUNCTION IF EXISTS pmt_activity_listview_ct(character varying, character varying, character varying, date, date) CASCADE;

DROP TYPE IF EXISTS pmt_activity_listview_result CASCADE;

CREATE TYPE pmt_activity_listview_result AS (response json);

/******************************************************************
  pmt_activity_listview
******************************************************************/
CREATE OR REPLACE FUNCTION pmt_activity_listview(tax_id integer, classification_ids character varying, organization_ids character varying, unassigned_tax_ids character varying, 
start_date date, end_date date, orderby text, limit_rec integer, offset_rec integer)
RETURNS SETOF pmt_activity_listview_result AS 
$$
DECLARE
  valid_taxonomy_id boolean;
  report_by_category boolean; 
  report_taxonomy_id integer;
  filter_classids integer array;
  filter_orgids integer array;
  include_taxids integer array;  
  rec record;  
  dynamic_where1 text array;
  dynamic_where2 text;
  built_where text array; 
  execute_statement text;
  count_statement text;
  paging_statement text;
  record_count integer;
  i integer;
BEGIN

-- validate and process taxonomy_id parameter
SELECT INTO valid_taxonomy_id * FROM pmt_validate_taxonomy($1); 

-- Must have valid taxonomy_id parameter to continue
IF NOT valid_taxonomy_id THEN
  RAISE NOTICE '   + A taxonomy is required.';
-- Has a valid taxonomy_id parameter 
ELSE
  report_taxonomy_id := $1;
  -- is this taxonomy a category?
  SELECT INTO report_by_category is_category FROM taxonomy WHERE taxonomy_id = (report_taxonomy_id);      
  -- yes, this is a category taxonomy
  IF report_by_category THEN
    -- what are the root taxonomy(ies) of the category taxonomy
    SELECT INTO report_taxonomy_id * FROM pmt_category_root(report_taxonomy_id, null);		    
    IF report_taxonomy_id IS NULL THEN
      -- there is no root taxonomy
      report_taxonomy_id := $1;
      report_by_category := false;
    END IF;
  END IF;

    -- filter by classification ids
    IF ($2 is not null AND $2 <> '') THEN
      RAISE NOTICE '   + The classification filter is: %.', string_to_array($2, ',')::int[];

	SELECT INTO filter_classids * FROM pmt_validate_classifications($2);

	IF filter_classids IS NOT NULL THEN
	  -- Loop through each taxonomy classification group to contruct the where statement 
	  FOR rec IN( SELECT tc.taxonomy_id, array_agg(tc.classification_id) AS filter_array 
	  FROM taxonomy_classifications tc WHERE classification_id = ANY(filter_classids) GROUP BY tc.taxonomy_id
	  ) LOOP				
		built_where := null;
		-- for each classification add to the where statement
		FOREACH i IN ARRAY rec.filter_array LOOP 
		  built_where :=  array_append(built_where, 'classification_ids @> ARRAY['|| i ||']');
		END LOOP;
		-- add each classification within the same taxonomy to the where joined by 'OR'
		dynamic_where1 := array_append(dynamic_where1, '(' || array_to_string(built_where, ' OR ') || ')');
	  END LOOP;			
	END IF;
    END IF;
   
    -- filter by organization ids
    IF ($3 is not null AND $3 <> '') THEN
      RAISE NOTICE '   + The organization filter is: %.', string_to_array($3, ',')::int[];

      -- Create an int array from organization ids list
	filter_orgids := string_to_array($3, ',')::int[];

      -- Loop through the organization_ids and construct the where statement
	built_where := null;
	FOREACH i IN ARRAY filter_orgids LOOP
		built_where :=  array_append(built_where, 't1.organization_id = '|| i );
	END LOOP;
	-- Add the complied org statements to the where
	dynamic_where1 := array_append(dynamic_where1, '(' || array_to_string(built_where, ' OR ') || ')');
	
   END IF;

    -- include values with unassigned taxonomy(ies)
    IF ($4 is not null AND $4 <> '') THEN
      RAISE NOTICE '   + The include unassigned is: %.', string_to_array($4, ',')::int[];

      -- Create an int array from unassigned ids list
      include_taxids := string_to_array($4, ',')::int[];				

      -- Loop through the organization_ids and construct the where statement
      built_where := null;
      FOREACH i IN ARRAY include_taxids LOOP
	built_where :=  array_append(built_where, 'not (taxonomy_ids @> ARRAY['|| i ||'])');
      END LOOP;			
      -- Add the complied org statements to the where
      dynamic_where2 := '(' || array_to_string(built_where, ' OR ') || ')';
	
    END IF;

    -- filter by date range
    IF ($5 is not null AND $6 is not null) THEN
	dynamic_where1 := array_append(dynamic_where1, '(t1.start_date > ''' || $5 || ''' AND t1.end_date < ''' || $6 || ''')');
    END IF;	
    
    -- create dynamic paging statment
    IF $7 IS NOT NULL AND $7 <> '' THEN
      IF paging_statement IS NOT NULL THEN
        paging_statement := paging_statement || 'ORDER BY ' || $7 || ' ';
      ELSE
        paging_statement := ' ORDER BY ' || $7 || ' ';
      END IF;
    END IF;		    
    IF $8 IS NOT NULL AND $8 > 0 THEN
      IF paging_statement IS NOT NULL THEN
        paging_statement := paging_statement || 'LIMIT ' || $8 || ' ';
      ELSE
        paging_statement := ' LIMIT ' || $8 || ' ';
      END IF;
    END IF;		
    IF $9 IS NOT NULL AND $9 > 0 THEN
      IF paging_statement IS NOT NULL THEN
        paging_statement := paging_statement || 'OFFSET ' || $9 || ' ';
      ELSE
        paging_statement := ' OFFSET ' || $9 || ' ';
      END IF;      
    END IF;		

    -- prepare statement				
    RAISE NOTICE '   + The reporting taxonomy is: %', $1;
    RAISE NOTICE '   + The base taxonomy is: % ', report_taxonomy_id;												
    RAISE NOTICE '   + First where statement: %', array_to_string(dynamic_where1, ' AND ');
    RAISE NOTICE '   + Second where statement: %', dynamic_where2;
    RAISE NOTICE '   + The paging statement: %', paging_statement;
		
    -- prepare statement for the selection
    execute_statement := 'SELECT filter.activity_id AS a_id, filter.title AS a_name, filter.description AS a_desc, filter.start_date as a_date1, f.amount, filter.name as o_name, l.gaul, report_by.name as r_name   ' ||
			'FROM ( SELECT t1.activity_id, a.title, a.description, a.start_date, t1.organization_id, o.name FROM  ' ||
			-- filter 
			'(SELECT * FROM organization_lookup ) as t1 ' ||
			-- activity
			'JOIN (SELECT activity_id, title, description, start_date, end_date from activity) as a ' ||
			'ON t1.activity_id = a.activity_id ' ||
			-- organization
			'JOIN (SELECT organization_id, name from organization) as o ' ||
			'ON t1.organization_id = o.organization_id ';			
			
    -- append where statements			
    IF dynamic_where1 IS NOT NULL THEN          
      IF dynamic_where2 IS NOT NULL THEN
        execute_statement := execute_statement || ' WHERE ' ||  array_to_string(dynamic_where1, ' AND ')  || ' OR ' || dynamic_where2;
      ELSE
        execute_statement := execute_statement || ' WHERE ' ||  array_to_string(dynamic_where1, ' AND ') || ' ';
      END IF;
    ELSE 
      IF dynamic_where2 IS NOT NULL THEN
        execute_statement := execute_statement || ' WHERE ' || dynamic_where2 || ' ';                       
      END IF;
    END IF;	

    IF report_by_category THEN
      execute_statement := execute_statement || ') as filter ' ||
			-- report by
			'LEFT JOIN (SELECT DISTINCT tl.activity_id, cc.name FROM taxonomy_lookup tl ' ||
			'JOIN classification c ON tl.classification_id = c.classification_id ' ||
			'JOIN classification cc ON c.category_id = cc.classification_id ' ||
			-- dynamic where
			'WHERE tl.taxonomy_id = ' || report_taxonomy_id ||') as report_by ' ||			
			'ON filter.activity_id = report_by.activity_id ' ||
			'GROUP BY filter.activity_id, filter.title, filter.organization_id, filter.name ';
    ELSE
      execute_statement := execute_statement || ') as filter ' ||
			-- report by
			'LEFT JOIN (SELECT DISTINCT tl.activity_id, array_to_string(array_agg(distinct c.name), '','') as name FROM taxonomy_lookup tl ' ||
			'JOIN classification c ON tl.classification_id = c.classification_id ' ||
			-- dynamic where
			'WHERE tl.taxonomy_id = ' || report_taxonomy_id ||' GROUP BY tl.activity_id ) as report_by ' ||			
			'ON filter.activity_id = report_by.activity_id ';
    END IF;	

    execute_statement := execute_statement || 'LEFT JOIN (SELECT activity_id, array_to_string(array_agg(gaul0_name || '', '' || gaul1_name), ''; '') as gaul FROM location_lookup GROUP BY activity_id) as l ' ||
			'ON filter.activity_id = l.activity_id ' ||
			'LEFT JOIN (SELECT activity_id, sum(amount) as amount FROM financial GROUP BY activity_id) as f ' ||
			'ON filter.activity_id = f.activity_id'; 			
    
    -- if there is a paging request then add it
    IF paging_statement IS NOT NULL THEN 
      execute_statement := execute_statement || ' ' || paging_statement;
    END IF;
    
    -- execute statement		
    RAISE NOTICE 'execute: %', 'SELECT row_to_json(j) FROM (' || execute_statement || ')j';	   
     
    FOR rec IN EXECUTE 'SELECT row_to_json(j) FROM (' || execute_statement || ')j' LOOP     
	RETURN NEXT rec;
    END LOOP;	

END IF; -- Must have valid taxonomy_id parameter to continue

END;$$ LANGUAGE plpgsql;
/******************************************************************
  pmt_activity_listview_ct
******************************************************************/
CREATE OR REPLACE FUNCTION pmt_activity_listview_ct(classification_ids character varying, organization_ids character varying, unassigned_tax_ids character varying, start_date date, end_date date)
RETURNS INT AS 
$$
DECLARE
  valid_taxonomy_id boolean;
  report_by_category boolean; 
  report_taxonomy_id integer;
  filter_classids integer array;
  filter_orgids integer array;
  include_taxids integer array;  
  rec record;  
  dynamic_where1 text array;
  dynamic_where2 text;
  built_where text array; 
  execute_statement text;
  count_statement text;
  paging_statement text;
  record_count integer;
  i integer;
BEGIN


    -- filter by classification ids
    IF ($1 is not null AND $1 <> '') THEN
      RAISE NOTICE '   + The classification filter is: %.', string_to_array($1, ',')::int[];

	SELECT INTO filter_classids * FROM pmt_validate_classifications($1);

	IF filter_classids IS NOT NULL THEN
	  -- Loop through each taxonomy classification group to contruct the where statement 
	  FOR rec IN( SELECT tc.taxonomy_id, array_agg(tc.classification_id) AS filter_array 
	  FROM taxonomy_classifications tc WHERE classification_id = ANY(filter_classids) GROUP BY tc.taxonomy_id
	  ) LOOP				
		built_where := null;
		-- for each classification add to the where statement
		FOREACH i IN ARRAY rec.filter_array LOOP 
		  built_where :=  array_append(built_where, 'classification_ids @> ARRAY['|| i ||']');
		END LOOP;
		-- add each classification within the same taxonomy to the where joined by 'OR'
		dynamic_where1 := array_append(dynamic_where1, '(' || array_to_string(built_where, ' OR ') || ')');
	  END LOOP;			
	END IF;
    END IF;
   
    -- filter by organization ids
    IF ($2 is not null AND $2 <> '') THEN
      RAISE NOTICE '   + The organization filter is: %.', string_to_array($2, ',')::int[];

      -- Create an int array from organization ids list
	filter_orgids := string_to_array($2, ',')::int[];

      -- Loop through the organization_ids and construct the where statement
	built_where := null;
	FOREACH i IN ARRAY filter_orgids LOOP
		built_where :=  array_append(built_where, 'organization_ids @> ARRAY['|| i ||']');
	END LOOP;
	-- Add the complied org statements to the where
	dynamic_where1 := array_append(dynamic_where1, '(' || array_to_string(built_where, ' OR ') || ')');
	
   END IF;

    -- include values with unassigned taxonomy(ies)
    IF ($3 is not null AND $3 <> '') THEN
      RAISE NOTICE '   + The include unassigned is: %.', string_to_array($3, ',')::int[];

      -- Create an int array from unassigned ids list
      include_taxids := string_to_array($3, ',')::int[];				

      -- Loop through the organization_ids and construct the where statement
      built_where := null;
      FOREACH i IN ARRAY include_taxids LOOP
	built_where :=  array_append(built_where, 'not (taxonomy_ids @> ARRAY['|| i ||'])');
      END LOOP;			
      -- Add the complied org statements to the where
      dynamic_where2 := '(' || array_to_string(built_where, ' OR ') || ')';
	
    END IF;

     -- filter by date range
    IF ($4 is not null AND $5 is not null) THEN
	dynamic_where1 := array_append(dynamic_where1, '(start_date > ''' || $4 || ''' AND end_date < ''' || $5 || ''')');
    END IF;
    
    -- prepare statement																
    RAISE NOTICE '   + First where statement: %', array_to_string(dynamic_where1, ' AND ');
    RAISE NOTICE '   + Second where statement: %', dynamic_where2;

    -- prepare the statement for the record count (can be leaner for faster exectution)
    count_statement := 'SELECT COUNT(DISTINCT a_id) FROM(SELECT DISTINCT filter.activity_id AS a_id, filter.organization_id as o_id ' ||
			'FROM (SELECT t1.activity_id, t1.organization_id FROM ' ||
			'(SELECT activity_id, organization_id, start_date, end_date, array_agg(distinct taxonomy_id) as taxonomy_ids, array_agg(distinct classification_id) as classification_ids, array_agg(distinct organization_id) as organization_ids ' ||
			'FROM taxonomy_lookup GROUP BY activity_id, organization_id, start_date, end_date ) as t1 ';			
   
    -- append where statements			
    IF dynamic_where1 IS NOT NULL THEN          
      IF dynamic_where2 IS NOT NULL THEN
        count_statement := count_statement || ' WHERE ' ||  array_to_string(dynamic_where1, ' AND ')  || ' OR ' || dynamic_where2;
      ELSE
        count_statement := count_statement || ' WHERE ' ||  array_to_string(dynamic_where1, ' AND ') || ' ';
      END IF;
    ELSE 
      IF dynamic_where2 IS NOT NULL THEN
        count_statement := count_statement || ' WHERE ' || dynamic_where2 || ' ';
      END IF;
    END IF;	

    count_statement := count_statement || ') as filter ) as count';	 
    
    -- get total record count
    EXECUTE count_statement INTO record_count;

    RETURN record_count;

END;$$ LANGUAGE plpgsql;

-- update permissions
GRANT USAGE ON SCHEMA public TO pmt_read;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pmt_read;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO pmt_read;
GRANT USAGE ON SCHEMA public TO pmt_write;
GRANT SELECT,INSERT ON ALL TABLES IN SCHEMA public TO pmt_write;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO pmt_write;