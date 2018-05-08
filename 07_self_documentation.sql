SELECT '--- 07 Self Documentation ---' AS title ;

-- You may have noticed up to now that I have been using triple hiphon comments
-- within function bodies. This is so that we can provide the client with what
-- I refer to as self-documentation. You may recognis this technique from
-- languages such as python which has a similar triple quote feature.

-- To extract the documentation for all procedures in the 'customer' schema we
-- need a function that looks like this:

CREATE FUNCTION customer.get_api_documentation() RETURNS TABLE(name name, description TEXT, result TEXT, arguments TEXT) AS $$
	SELECT
		sub.name, array_to_string(array_agg(sub.src), E'\n'), result_data_type, argument_data_types
	FROM (
		SELECT	
				p.proname as name,
			array_to_string(regexp_matches(prosrc, E'---(.*)', 'gn'), ' ') AS src,
			pg_catalog.pg_get_function_result(p.oid) as "result_data_type",
			pg_catalog.pg_get_function_arguments(p.oid) as "argument_data_types"
		FROM pg_catalog.pg_proc p
			LEFT JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
		WHERE n.nspname = 'customer'
		AND p.proname != 'get_api_documentation'
		GROUP BY p.oid, p.proname, p.prosrc 
	) sub
	GROUP BY sub.name, sub.result_data_type, sub.argument_data_types ;

$$ LANGUAGE SQL STABLE SECURITY DEFINER ;

SELECT 'Let''s give the documentation viewer a test.' AS msg ;
SELECT * FROM customer.get_api_documentation();

ROLLBACK ;
