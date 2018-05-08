SELECT '--- 05 Security ---' AS title ;

-- Now that we can get our current user_id with core.get_user_id() we can
-- determine which row the client can access and how.

-- So lets start with a trivial model to demonstrate. Hence forth we'll be
-- making a very simple appointment application. For this we'll need an
-- appointments relation, a signup relation and methods for modifying both.
-- All users will be able to create appointments but only the creator of an
-- appointment will be able to modify it and create or remove signups.

SELECT 'Our appointment table will start out quite simple' AS msg ;
CREATE TABLE core.appointment (
	  id SERIAL PRIMARY KEY
	, name TEXT NOT NULL
	, start_time TIMESTAMPTZ NOT NULL
	, end_time TIMESTAMPTZ NOT NULL
	, owner INT NOT NULL REFERENCES core.user ON DELETE SET NULL
);

SELECT 'The sign up table can just be a simple many-to-many relational table.' AS msg ;
CREATE TABLE core.appointment_signup (
	  user_id INT NOT NULL REFERENCES core.user ON DELETE CASCADE
	, appointment_id INT NOT NULL REFERENCES core.appointment ON DELETE CASCADE
	, created_time TIMESTAMPTZ NOT NULL DEFAULT NOW()
	, PRIMARY KEY(user_id, appointment_id)
);


SELECT ' Now let''s make a view to access the table.' AS msg ;
CREATE VIEW customer.appointment WITH(security_barrier) AS
	SELECT
		DISTINCT a.*
	FROM core.get_user_id() my_user_id
		, core.appointment a
	LEFT JOIN core.appointment_signup aps
		ON aps.appointment_id = a.id
	WHERE a.owner = my_user_id
	OR my_user_id = aps.user_id
;

-- So when the client selects from the view they can only see appointment that
-- they 'own' or are signed up for.

-- Note that I added the get_user_id as a relation and not in the where clause.
-- This is to avoid running the function once per row which postgres
-- MAY (but seldom) do during execution. It also implicity stops updates to the
-- view as any view that selects from multiple tables is automatically read
-- only.

-- At this point I should explain the WITH(security_barrier) : Without this 
-- directive postgres will execute where claused in order of cost, thus if the
-- client were able to create a function like so:

CREATE FUNCTION dump_appointments(customer.appointment) RETURNS BOOL AS $$
BEGIN
	RAISE NOTICE '%', $1::TEXT ;
	RETURN TRUE ;
END
$$ LANGUAGE plpgsql COST 1 ;

-- And then call it like this

SELECT * FROM customer.appointment a WHERE dump_appointments(a);

-- Then postgres would run this function before a.owner = core.get_user_id() as
-- postgres would see it as a lower cost methid of reducing rows which would 
-- output rows that we do not want the client to see. By using
-- WITH(security_barrier) we force postgres to run the security WHERE clause
-- first.
DROP FUNCTION dump_appointments(customer.appointment);

-- But what about creating?

SELECT 'For creating new appointments we have two choices. Either create a dedicated
		procedure or add an INSERT TRIGGER. For the sake of thoroughness lets do
		both.' AS msg ;

CREATE FUNCTION customer.create_appointment(
	  name core.appointment.name%TYPE
	, start_time TIMESTAMPTZ
	, end_time TIMESTAMPTZ
) RETURNS core.appointment AS $$
DECLARE
	user_id INT := core.get_user_id(); -- This also stops unauthenticated users.
	new_appointment customer.appointment ;
BEGIN
	--- Takes a name, start_time and end_time and created a new appointment
	--- returns the new appointment.

	INSERT INTO core.appointment AS a (name, start_time, end_time, owner) VALUES (
		  create_appointment.name
		, create_appointment.start_time
		, create_appointment.end_time
		, user_id
	) RETURNING a.* INTO new_appointment ;
	RETURN new_appointment ;
END
$$ LANGUAGE plpgsql SECURITY DEFINER ;

SELECT 'Now the trigger version.' AS msg ;
CREATE FUNCTION core.customer_create_appointment_trigger() RETURNS TRIGGER AS $$
DECLARE
	my_user_id INT := core.get_user_id();
BEGIN
	INSERT INTO core.appointment AS a (name, start_time, end_time, owner) VALUES (
		  NEW.name
		, NEW.start_time
		, NEW.end_time
		, my_user_id
	) RETURNING a.* INTO NEW ; -- Important!
	RETURN NEW ; -- We can't use RETURNING at the view level without this.
	-- which you may not notice until you need to use it.
END
$$ LANGUAGE plpgsql SECURITY DEFINER ;

CREATE TRIGGER customer_create_appointment_trigger INSTEAD OF INSERT ON
	customer.appointment FOR EACH ROW
	EXECUTE PROCEDURE core.customer_create_appointment_trigger();

-- The jury is out on which is better. The funcion allows you to add extra
-- input that falls outside the table, such as additional flags or paramaters
-- instructing the function to generate the end_time. In this case we could
-- have an overload in which a duration is passed instead of an end time. On
-- the other hand a trigger may be more natural for an application. We could
-- also have a trigger that simply calls the procedure.

CREATE OR REPLACE FUNCTION core.customer_create_appointment_trigger() RETURNS TRIGGER AS $$
BEGIN
	SELECT * INTO NEW FROM customer.create_appointment(
		  name       := NEW.name
		, start_time := NEW.start_time
		, end_time   := NEW.end_time
	);
	RETURN NEW ;
END
$$ LANGUAGE plpgsql SECURITY DEFINER ;

-- Which gives us the best of both worlds.


-- But what about UPDATES?

-- Well the update for appointments is quite easy as clients should always be
-- able to update their own appointments. However we don't want to allow them
-- to change the id or owner fields.

CREATE FUNCTION core.customer_update_appointment() RETURNS TRIGGER AS $$
DECLARE
	user_id INT = core.get_user_id();
BEGIN
	IF OLD.owner != user_id THEN
		RAISE EXCEPTION 'Cannot update appointment %', OLD.name ;
	END IF ;

	UPDATE core.appointment
		SET name = NEW.name
		, start_time = NEW.start_time
		, end_time = NEW.end_time
	WHERE id = OLD.id -- Must be OLD id not NEW.
	RETURNING * INTO NEW ;
	RETURN NEW ;
END
$$ LANGUAGE plpgsql ;

CREATE TRIGGER customer_update_appointment_trigger INSTEAD OF UPDATE ON 
	customer.appointment FOR EACH ROW EXECUTE PROCEDURE
	core.customer_update_appointment();


-- For updated I would always recommend using a trigger. The alternative
-- function is very long winded and looks something like this

-- Note that this will only edit the name but you can work out the rest.
CREATE FUNCTION customer.update_appointment(id INT, name TEXT = NULL) RETURNS customer.appointment AS $$
DECLARE
	user_id INT := core.get_user_id();
	altered_appointment customer.appointment ;
BEGIN
	UPDATE core.appointment AS a
		SET a.name = COALESCE(update_appointment.name, a.name) -- Loooong
	WHERE a.id = OLD.id
	AND a.owner = user_id
	RETURNING a INTO altered_appointment ;

	RETURN altered_appointment ;
END
$$ LANGUAGE plpgsql ;

-- But this is really quite rubbish. Consider how a client would specificly 
-- NULL a field. They can't.

-- Also one would have to perform a select first to find the initial values
-- in order to throw a descriptive error.

-- Plus having a procedure stops the client from updating several rows at once
-- or doing something like:
-- 		UPDATE customer.appointment SET name = name || ' more name text' WHERE ...
DROP FUNCTION customer.update_appointment(INT, TEXT);

-- Also in the update trigger we can do this:
-- 		SET name = DEFAULT
--  But unfortunately not
--      SET name = COALESCE(NEW.name, DEFAULT)

-- As the DEFAULT is not a real value. :(


-- Finally a DELETE. Again I would recommend a trigger for this for the sake
-- of multi-row deletions. Again we don't need to check security here as
-- the rows can only be viewed by the owner.

CREATE FUNCTION customer_delete_appointment() RETURNS TRIGGER AS $$
DECLARE
	my_user_id INT = core.get_user_id();
BEGIN
	IF OLD.owner != my_user_id THEN
		RAISE EXCEPTION 'Cannot delete appointment %', OLD.name ;
	END IF ;

	DELETE FROM core.appointment a WHERE a.id = OLD.id ;
  	RETURN OLD ;
END
$$ LANGUAGE plpgsql SECURITY DEFINER ;

CREATE TRIGGER customer_delete_appointment_trigger INSTEAD OF DELETE ON 
	customer.appointment FOR EACH ROW EXECUTE PROCEDURE
	customer_delete_appointment();

-- Last but not least we need a set of functions to modify the signups. As
-- this is a many-to-many relation the client is unlikely to update rows but
-- rather delete and re-create them. As a result we can simply make two
-- seperate and simple functions.

CREATE FUNCTION core.check_appointment_ownership(appointment_id INT) RETURNS VOID AS $$
DECLARE
	my_user_id INT = core.get_user_id();
	appointment core.appointment ;
BEGIN
	SELECT a.* INTO appointment FROM core.appointment a
	WHERE a.id = check_appointment_ownership.appointment_id ;

	IF appointment IS NULL THEN 
		RAISE EXCEPTION 'No such appointment' ;
	END IF ;

	IF appointment.owner != my_user_id THEN
		RAISE EXCEPTION 'You don''t own this appointment' ;
	END IF ;

END
$$ LANGUAGE plpgsql STABLE ;

CREATE FUNCTION customer.create_appointment_signup(appointment_id INT, user_id INT) RETURNS VOID AS $$
	SELECT core.check_appointment_ownership(appointment_id := create_appointment_signup.appointment_id);
	INSERT INTO core.appointment_signup (appointment_id, user_id) VALUES (
		  create_appointment_signup.appointment_id
		, create_appointment_signup.user_id
	);
$$ LANGUAGE SQL SECURITY DEFINER ;

CREATE FUNCTION customer.delete_appointment_signup(appointment_id INT, user_id INT) RETURNS VOID AS $$
	SELECT core.check_appointment_ownership(appointment_id := delete_appointment_signup.appointment_id);

	DELETE FROM core.appointment_signup aps
	WHERE aps.appointment_id = delete_appointment_signup.appointment_id
	AND aps.user_id = delete_appointment_signup.user_id ;
$$ LANGUAGE SQL ;

SELECT 'Now let''s give it all a quick test.' AS msg ;
INSERT INTO customer.appointment(name, start_time, end_time) VALUES ('Meeting', '2025-09-20 09:00:00', '2025-09-20 11:00:00');
SELECT customer.create_appointment_signup(appointment_id := 1, user_id := 1);


-- Simple enough. But with these simple techniques we can do so much more.
-- In later chapters we will build on what we have here and make significantly
-- more complex security models. So stay tuned.
