BEGIN ;

-- Always use schemas!
-- Organizing your tables, views and functions into schemas has several advantages:
--  1) It keeps tables organied especially when querying information_schema.
--  2) Permissions can be set accross the schema rather than table-by-table.
--  3) Otherwise protexted keywords like 'user' can be used as table names.

-- CREATE TABLE user (); -- This won't work as 'user' is a keyword.

CREATE SCHEMA core ;

CREATE TABLE core.user (
	  id SERIAL PRIMARY KEY
	, username TEXT NOT NULL UNIQUE
	, password TEXT NOT NULL
);

INSERT INTO core.user (username, password) VALUES ('Testy McTesterson', 'This shouldn''t be plain text.');

CREATE SCHEMA customer ;

CREATE VIEW customer.user WITH(security_barrier) AS -- security_barrier will be explained later.
	SELECT
		  id
		, username
		, '*****'::TEXT AS password
	FROM
		core.user
;

GRANT USAGE ON SCHEMA customer TO public ;
GRANT SELECT ON ALL TABLES IN SCHEMA customer TO public ;

-- Now anything in schema core is hidden from public and access
-- can be controlled through the customer schema.

CREATE USER tmctesterson ;
SET ROLE tmctesterson ;

SELECT * FROM customer.user ;

COMMIT ;
