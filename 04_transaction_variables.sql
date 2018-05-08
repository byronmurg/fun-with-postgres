SELECT '--- 04 Transaction variables ---' AS title ;

-- Transaction variables are a slighly hacky way of storing information
-- within the current transaction.
-- Consider that postgres security is based on the connection itself
-- but in a real world application a web server of client would need
-- to switch into an application user to avoid users being able to
-- access data which the postgresql client would otherwise have access
-- to.

-- Let's consider the options available:
-- 1) Creating an application security layer:
--      e.g SELECT * FROM core.account WHERE user_id = ? ;
-- 		This is probably the most common method of restricting access
--		and as a result there are many ORMs and abstraction libraries
--      available to make this easier. The problem with this method is
--		clarity; consider if we require a more complex query
--      SELECT
-- 			SUM(t.amount)
--		FROM
--			  core.account u
--			, core.transaction t
--		WHERE t.account_id = u.id
--		AND   u.user_id = ?
--      GROUP BY u.* ;

--  	Now if I want to get the data but join on annother table or
--  	change the aggregate we would have to REPEAT THE WHOLE QUERY.
--		Also consider more complex situations for example a transation
--  	log where both the sender and reciever can see a row but only
--  	the sender can see which account the money came out of. Or how
-- 		about if we wanted a more complex user -> user_group -> permission
--		model. Alternatively what if an account can be viewed by several
--		users in a group? We very quickly end up with complex queries
--		that become very repetative. In the worst case scenario imagine
--		if two programmers who have slightly different understandings of
--		what a user should be able to see allow access to different parts
--		of the data and accidently allow some priviledge escaltion as a
--		result!
--
--		Also ask where the user_id is retrieved from. I have seen many many
--		web applications where the developers have used whole other
-- 		technologies just to map a browser cookie to a user id which then
--		has to by syncronized and distributed and blah blah blah.

-- 2) Row level security.
--		Starting in postgresql 9.5 we can now instruct postgresql to
--		restrict access to both rows and columns to specific users.
--		I'm not going to delve too much into the feature here but I
--		would recommend being aware of it. I am however going to give
--		you several reasons not to use it.
-- 		1) It's designed to limit access to postgres users making it
--			difficult (but possible) to use in a web application scenario.
--		2) Permission is calculated row by row so if we have a complex
--			permission system the queries will be repeated. Although
--			postgres caching will take away most of the burden this is
--			not ideal.
--		3) You can hide columns but not add them. As you will see later
--			you can add columns to security views such as can_edit (bool)
--			which makes deducting whether or not data can be modified
--			alot easier.
--		4) Joining to tables with row level security will force any
--			security calculations to be performed twice.
--
--		In conclusion; row level security can be very useful in certain
--		application but on the whole I feel that it is a poor feature.

-- 3) Using session variables:
--		In postgres you can set a variable for the duration of the current
--		transaction. The one caveat is that the variables must contain a
--		dot "." to seperate them from postgres setting variables.
--
--		By using session variables we can access the user_id from deep
--		within a function or even view without passing in paramaters.
--		We do this by setting a session_key to the variable then reading
--		it through a function which translates it to a user_id. Bear in
--		mind that transaction variables can be set by the user so you
--		shouldn't store a user_id directly in one. However a session_key
--		would be fine.
--
--		This means that we could potentially create views that show the
--		user only the rows that they are meant to see. And then only
--		the columns that they are meant to see.
--		Thus our application would access the database like so:
--		BEGIN ;
--		SELECT customer.set_session_key("session_key" := 'THE KEY');
--		access or modify data.
-- 		COMMIT ;
--		-- or --
--		ROLLBACK ;


SELECT 'First lets create a simple type to check that the session key looks
		remotely valid. This is just to avoid spending too much time on
		blank session keys.' AS msg ;
CREATE DOMAIN session_key AS CHAR(32) CONSTRAINT "Invalid session key" CHECK(LENGTH(VALUE) = 32);

SELECT 'We also have to create an initial value otherwise an exception will be
		thrown when we try to access it when unset.' AS msg ;
ALTER ROLE web_interface SET application.session_key = '' ;
-- Alternatively you can set this in postgresql.conf


SELECT 'We''re going need a session table.' AS msg ;
CREATE TABLE core.user_session (
	  session_key session_key PRIMARY KEY DEFAULT MD5(RANDOM()::TEXT)
	, user_id INT NOT NULL REFERENCES core.user ON DELETE CASCADE
	, expires TIMESTAMPTZ NOT NULL DEFAULT NOW() + core.get_global('session duration')::INTERVAL
);


SELECT 'Now we need a way of setting the session key.' AS msg ;
CREATE FUNCTION customer.set_session_key(session_key session_key) RETURNS VOID AS $$
BEGIN
	--- Set the session key transaction variable.
	PERFORM set_config('application.session_key', set_session_key.session_key, TRUE);
END
$$ LANGUAGE plpgsql SECURITY DEFINER ; 


SELECT 'And a way of getting the session key.' AS msg ;
CREATE FUNCTION core.get_session_key() RETURNS session_key AS $$
	-- Read the session key from the transaction variable.
	SELECT NULLIF(current_setting('application.session_key'), '')::session_key ;
$$ LANGUAGE SQL SECURITY DEFINER ;


SELECT 'We''ll also want a function to get the user id easily and
		stop execution when the session key is invalid. ' AS msg ;
CREATE FUNCTION core.get_user_id() RETURNS core.user.id%TYPE AS $$
DECLARE
	user_id INT := NULL ;
	my_session_key session_key := core.get_session_key();
BEGIN
	--- Get the user_id from the saved session key
	--- raising an exception if there is no corresponding
	--- key in the core.session table.

	IF my_session_key IS NULL THEN
		RAISE EXCEPTION 'session key not set' ;
	END IF ;

	SELECT
		  s.user_id INTO user_id
	FROM
		core.user_session s
	WHERE s.expires > NOW()
	AND s.session_key = my_session_key ;

	IF user_id IS NULL THEN
		RAISE EXCEPTION 'session key is set but invalid.' ;
	END IF ;

	RETURN user_id ;
END
$$ LANGUAGE plpgsql STABLE ;


SELECT 'And finally a way to log in' AS msg ;
CREATE FUNCTION customer.login(
	  username core.user.username%TYPE
	, password TEXT
) RETURNS session_key AS $$
DECLARE
	new_session_key session_key ;
	user_id INT := NULL ;
BEGIN 
	-- Log in and return a session key. Will also set the session key of the
	-- current transaction. Must commit after calling.

	SELECT
		  u.id INTO user_id
	FROM
		  core.user u
	WHERE u.username = login.username
	AND   u.password = core.encode_password("password" := login.password) ;

	IF user_id IS NULL THEN
		RAISE EXCEPTION 'Incorrect login/password' ;
	END IF ;

	INSERT INTO core.user_session (user_id)
	VALUES (user_id) RETURNING session_key INTO new_session_key ;

	PERFORM customer.set_session_key(new_session_key);

	RETURN new_session_key ;
END
$$ LANGUAGE plpgsql SECURITY DEFINER ;

-- So let's give it a spin.
SELECT customer.login(username := 'Testy McTesterson', password := 't35Ty !s 1337');
SELECT core.get_session_key();
SELECT core.get_user_id();

-- Great! We can now find our user id and check for a login while nested deep
-- within a query. The only pre-requisite is that we must be inside a
-- transaction which is generaly a good idea anyway.
