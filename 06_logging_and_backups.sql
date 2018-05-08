SELECT '--- 06 Logging and backups ---' AS title ;

-- In any major application you will need to keep a log of client actions.
-- From both the perspective of the user and relation object we want a way to
-- determine what changes have happened and when. In most applications this is
-- handled at the code level even if records are then stored in the database.

-- We also need a way of rolling back changes. Sometimes a client has made a
-- mistake or circumstances change.

-- What if I told you that both of these pieces of functionlity could be
-- handled entirely within the database. Thanks to JSON and JSONB functionality
-- added throughout later Postgresql v9 this is now very simple. I'm not going
-- to be able to give you a thorough explanation until you see the results so
-- for now just follow the schema and see what I mean...

-- We'll start with an enum for the type of change we will be making.
CREATE TYPE change_type AS ENUM('UPDATE', 'DELETE');


-- Next we'll need a way of reducing one JSON object from annother.
CREATE FUNCTION jsonb_reduce(left JSONB, right JSONB) RETURNS JSONB AS $$
DECLARE
    i TEXT := NULL ;
BEGIN
    FOR i IN ( SELECT key FROM jsonb_each($2) ) LOOP
        IF $2->>i IS NOT DISTINCT FROM $1->>i THEN
            $1 = $1 - i ;
        END IF ;
    END LOOP ;
    RETURN $1 ;
END ;
$$ LANGUAGE plpgsql IMMUTABLE ;
-- The immutable means that the output will output will always produce the same
-- output for a given input. It mainly helps with internal optimization.

-- Now we need a way of merging two JSON objects. Notice that only scalars and
-- objects are handled but not arrays.
CREATE FUNCTION jsonb_merge(left JSONB, right JSONB) RETURNS JSONB AS $$
DECLARE
    i TEXT := NULL ;
BEGIN
	left  := COALESCE($1,  '{}'::JSONB);
	right := COALESCE($2, '{}'::JSONB);

	FOR i IN (SELECT * FROM jsonb_each($2)) LOOP
		IF jsonb_typeof($2->i) = 'object' AND jsonb_typeof($1->i) = 'object' THEN
			$1 = jsonb_set($1, ARRAY[i], jsonb_merge($1->i, $2->i));
		ELSIF $1->i IS DISTINCT FROM $2->i THEN
			$1 = jsonb_set($1, ARRAY[i], $2->i);
		END IF ;
	END LOOP ;
	RETURN $1 ;
END ;
$$ LANGUAGE plpgsql IMMUTABLE ;

-- And a quick test.
SELECT jsonb_merge('{ "obj":{ "foo":"bar" } }'::JSONB, '{ "obj":{ "eggs":"ham" } }'::JSONB);


-- Now a table to store our log entries in.
CREATE TABLE core.object_log( 
	  id SERIAL PRIMARY KEY
    , userid INT NOT NULL REFERENCES core.user ON DELETE SET NULL
	, table_name TEXT NOT NULL
    , old_data JSONB NOT NULL
    , time TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp() -- Not NOW() which would give us the transaction time!
    , change_type change_type NOT NULL
);


-- This is where we get fancy. The log will be performed by AFTER UPDATE/DELETE
-- triggers. However the beauty of JSON types is that we won't need seperate
-- ones for each table.
CREATE FUNCTION core.log_object_update() RETURNS TRIGGER AS $$
DECLARE
	old_jsonb JSONB = to_jsonb(OLD.*);
	change_jsonb JSONB = jsonb_reduce(old_jsonb, to_jsonb(NEW.*));
	my_user_id INT := core.get_user_id();
	id_key TEXT = COALESCE(TG_ARGV[0], 'id');
	id INT = (old_jsonb->>id_key)::INT ;
BEGIN
	INSERT INTO core.object_log (table_name, old_data, change_type, userid)
	VALUES (TG_TABLE_NAME, change_jsonb, 'UPDATE', my_user_id);

	RETURN NEW ;
END
$$ LANGUAGE plpgsql SECURITY DEFINER ;

-- Also one for deletions. This can just serialize and store the row.
CREATE FUNCTION core.log_object_delete() RETURNS TRIGGER AS $$
DECLARE
	old_jsonb JSONB = to_jsonb(OLD.*);
	my_user_id INT := core.get_user_id();
	id_key TEXT = COALESCE(TG_ARGV[0], 'id');
	id INT = (old_jsonb->>id_key)::INT ;
BEGIN
	INSERT INTO core.object_log (table_name, old_data, change_type, userid)
	VALUES (TG_TABLE_NAME, old_jsonb, 'DELETE', my_user_id);

	RETURN OLD ;
END
$$ LANGUAGE plpgsql SECURITY DEFINER ;

-- Instead of the table name you could also use the oid hidden column of the
-- record which can then be matched to pg_class. This would give you a slight
-- speed and space advantage but reduce portability between installations. 

-- To apply the triggers we need to add them AFTER the change.

CREATE TRIGGER "log appointment update" AFTER UPDATE ON core.appointment FOR EACH ROW EXECUTE PROCEDURE core.log_object_update();
CREATE TRIGGER "log appointment delete" AFTER DELETE ON core.appointment FOR EACH ROW EXECUTE PROCEDURE core.log_object_delete();

CREATE TRIGGER "log appointment_signup delete" AFTER DELETE ON core.appointment_signup FOR EACH ROW EXECUTE PROCEDURE core.log_object_delete();

UPDATE customer.appointment SET name = name || ' an it''s important' WHERE id = 1 ;
UPDATE customer.appointment SET start_time = start_time + '1 hour'::INTERVAL WHERE id = 1 ;


-- Now we want a view for the clients to see their own changes.

CREATE VIEW customer.object_log WITH(security_barrier) AS
	SELECT * FROM
		  core.object_log ol
   		, core.get_user_id() my_user_id
	WHERE ol.userid = my_user_id
;

-- Let's have a look.
SELECT * FROM customer.object_log ;


CREATE FUNCTION core.retrieve_log_object(
	  id INT
	, table_name core.object_log.table_name%TYPE
	, to_data TIMESTAMPTZ = 'epoch'::TIMESTAMPTZ
) RETURNS JSONB AS $$
DECLARE
	buf JSONB := NULL ;
	merged JSONB := NULL ;
BEGIN
	FOR buf IN (
		SELECT
			old_data
		FROM
			core.object_log ol
		WHERE ol.old_data->'id' = to_jsonb(retrieve_log_object.id)
		AND ol.table_name = retrieve_log_object.table_name
		AND ol.time >= retrieve_log_object.to_data
		ORDER BY time DESC
	) LOOP
		merged := jsonb_merge(merged, buf);
	END LOOP ;
	RETURN merged ;
END
$$ LANGUAGE plpgsql STABLE ;

-- If we run the function you can see that it gives us a combined object of
-- all the changes made before the timestamp.
SELECT * FROM core.retrieve_log_object(id := 1, table_name := 'appointment', to_data := NOW() - '1 week'::INTERVAL);

-- Now for the actual recovery function we will have to create a relation
-- specific function. Firstly this is because a function cannot dynamically
-- cast into a type, even with an anyelement paramater. Secondly because in
-- practice you will want to recover more that just the object itself. For
-- example in this instance we also want to recover any signups that were
-- deleted by the CASCADE. Plus there will be cartain relations where you won't
-- want to recover all fields automatically, or maybe perform some additional
-- checks before recovery.

CREATE FUNCTION customer.rollback_appointment(appointment_id INT, to_data TIMESTAMP = 'epoch'::TIMESTAMPTZ) RETURNS customer.appointment AS $$
DECLARE
	appointment_jsonb JSONB ;
	current_appointment_jsonb JSONB ;
	return_appointment core.appointment ;
	my_user_id INT := core.get_user_id() ;
BEGIN
	--- Roll-back an appointment to a specific point in time. Also recovers
	--- appointment signups.

	SELECT to_jsonb(a.*) INTO current_appointment_jsonb
	FROM core.appointment a
	WHERE a.id = rollback_appointment.appointment_id ;

	IF current_appointment_jsonb->'owner' != to_jsonb(my_user_id) THEN
		RAISE EXCEPTION 'You do not have permission to rollback appointment %', rollback_appointment.appointment_id ;
	END IF ;

	SELECT core.retrieve_log_object(
		  id := rollback_appointment.appointment_id
		, table_name := 'appointment'
		, to_data := rollback_appointment.to_data
	) INTO appointment_jsonb ;

	appointment_jsonb := jsonb_merge(current_appointment_jsonb, appointment_jsonb);


	INSERT INTO core.appointment AS a
	SELECT * FROM jsonb_populate_record(null::core.appointment, appointment_jsonb)
	ON CONFLICT(id) DO UPDATE
		SET    name      = COALESCE(EXCLUDED.name, a.name)
			, start_time = COALESCE(EXCLUDED.start_time, a.start_time)
			, end_time   = COALESCE(EXCLUDED.end_time, a.end_time)
	RETURNING * INTO return_appointment ;

	FOR appointment_jsonb IN (
		SELECT old_data 
		FROM core.object_log ol
		WHERE ol.table_name = 'appointment_signup'
		AND ol.old_data->'appointment_id' = to_jsonb(rollback_appointment.appointment_id)
	) LOOP
		
		INSERT INTO core.appointment_signup AS aps
		SELECT * FROM jsonb_populate_record(null::core.appointment_signup, appointment_jsonb);
	END LOOP ;

	DELETE FROM core.appointment_signup aps
	WHERE aps.appointment_id = rollback_appointment.appointment_id
	AND aps.created_time >= to_data ;

	RETURN return_appointment ;
END
$$ LANGUAGE plpgsql SECURITY DEFINER ;

-- Note that this will work for both deleted and updated objects.

SELECT * FROM customer.appointment ;
SELECT customer.rollback_appointment(appointment_id := 1);
SELECT * FROM customer.appointment ;

-- Also notice that the recovery itself has been logged.
SELECT * FROM customer.object_log ;

SELECT 'No let''s try a delete.' AS msg ;
DELETE FROM customer.appointment WHERE id = 1 ;

SELECT 'We can see it in the log.' AS msg ;
SELECT * FROM customer.object_log WHERE change_type = 'DELETE' ;

SELECT 'Let''s try rolling it back.' AS msg ;
SELECT customer.rollback_appointment(appointment_id := 1);
SELECT * FROM customer.appointment ;

