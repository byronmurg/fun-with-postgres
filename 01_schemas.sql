SELECT '--- 01 Schemas ---' AS title ;
-- Always use schemas!
-- Organizing your tables, views and functions into schemas has several advantages:
--  1) It keeps tables organied especially when querying information_schema.
--  2) Permissions can be set accross the schema rather than table-by-table.
--  3) Otherwise protexted keywords like 'user' can be used as table names.

-- CREATE TABLE user (); -- This won't work as 'user' is a keyword.

SELECT 'Let''s start with a core schema.' AS msg ;
CREATE SCHEMA core ;

SELECT 'We''re also going to need a user table and we might as well make it now.' AS msg ;
CREATE TABLE core.user (
	  id SERIAL PRIMARY KEY
	, username TEXT NOT NULL UNIQUE
	, password TEXT NOT NULL
);

SELECT 'Now a schema for our customers to access' AS msg ;
CREATE SCHEMA customer ;

SELECT 'And a view for them to access the user table.' AS msg ;
CREATE VIEW customer.user WITH(security_barrier) AS -- security_barrier will be explained later.
	SELECT
		  id
		, username
		, '*****'::TEXT AS password
	FROM
		core.user
;

SELECT 'For the permissions we just GRANT customer schema usage to public.' AS msg ;
GRANT USAGE ON SCHEMA customer TO public ;
GRANT SELECT ON ALL TABLES IN SCHEMA customer TO public ;

-- Now anything in schema core is hidden from public and access
-- can be controlled through the customer schema.

SELECT 'And of course a Postgres user.' AS msg ;
CREATE USER web_interface WITH LOGIN PASSWORD 'This password won''t be used very often' ;

SELECT 'We can set the role to the new user to test what we''ve done.' AS msg ;
SET ROLE web_interface ;

SELECT * FROM customer.user ;

SET ROLE = DEFAULT ;
