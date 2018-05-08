SELECT '--- 03 Globals ---' AS title ;

-- It's great to have a globals table for various settings accross
-- your database. One of the nice things about postgres is that
-- any type can be cast from a string. I would recommend that you
-- use globals for column defaults like so:
-- CREATE TABLE something (
--    id SERIAL PRIMARY KEY
--    expires TIMESTAMPTZ DEFAULT NOW() + core.get_global('something duration')::INTERVAL
-- );
--
-- If nothing else it can be nice to seperate constants from the
-- database schema itself.

SELECT 'The global table can just be key -> value.' AS msg ;
CREATE TABLE core.globals (
	  key TEXT PRIMARY KEY
	, value TEXT NOT NULL
);

CREATE FUNCTION core.get_global(key TEXT) RETURNS TEXT AS $$
	SELECT value FROM core.globals g WHERE g.key = get_global.key ;
$$ LANGUAGE SQL SECURITY INVOKER STABLE STRICT ;

INSERT INTO core.globals VALUES ('session duration', '1 day');

SELECT core.get_global('session duration')::INTERVAL ;

-- In terms of security you should keep get_global inaccessible
-- from the clients. If there is a global that can be accessed by
-- clients simply make a dedicated function. Like this:
-- CREATE FUNCTION customer.get_session_duration() RETURNS INTERVAL AS $$
--     SELECT core.get_global('session duration')::INTERVAL ;
-- $$ LANGUAGE SQL STABLE SECURITY DEFINER ;

