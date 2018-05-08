SELECT '--- 02 Named parameters ---' AS title ; 

-- Named parameters are a great way to make postgresql function calls clearer
-- both to the programmer working with them and to postgresql when trying to
-- figure out which version of an overloaded function to use.

SELECT 'Lets create two trivial functions to demonstrate.' AS msg ;

CREATE FUNCTION say_hi(name TEXT, times INT) RETURNS VOID AS $$
DECLARE
	i INT := 0 ;
BEGIN
	FOR i IN SELECT generate_series(1, say_hi.times) LOOP
		RAISE NOTICE 'Hello %', say_hi.name ;
	END LOOP ;
END
$$ LANGUAGE plpgsql STABLE ;

SELECT say_hi("name" := current_user, "times" := 3);


-- Bear in mind that you cannot overload a function just by naming the
-- parameters differently:
-- CREATE FUNCTION say_hi(name TEXT, a_number INT) -- Too ambiguous!
-- This is because the overload id deduced from the order and type of
-- the parameters.

-- So the following is actially fine:

CREATE FUNCTION say_hi(a_number INT, name TEXT) RETURNS VOID AS $$
BEGIN
	RAISE NOTICE 'Hello % here''s a number : %', say_hi.name, say_hi.a_number ;
END
$$ LANGUAGE plpgsql STABLE ;

SELECT say_hi("name" := current_user, "a_number" := 20);

-- Because the parameters are swapped postgres knows which function
-- to call. Seems weird? I know.


-- Also beware when using parameter defaults. The following two functions 
-- would be too ambiguous:
-- CREATE FUNCTION say_hi(name TEXT)
-- CREATE FUNCTION say_hi(name TEXT, time INT = 0) -- EEK!
-- Beware that postgresql will let you create these functions but then
-- throw an exception when you call say_hi with only one text parameter.



-- Don't forget that you have to drop functions with the parameter types.
DROP FUNCTION say_hi(TEXT, INT);
DROP FUNCTION say_hi(INT, TEXT);
-- This can be be somewhat annoying and fiddly sometimes but it's also rare
-- to need to drop a function.



SELECT 'Now let''s tie this into our application.' AS msg ;

CREATE FUNCTION core.encode_password(
	password TEXT
) RETURNS core.user.password%TYPE AS $$
	SELECT MD5(encode_password.password); -- Obviously we would normally use a much better one way encoding.
$$ LANGUAGE SQL ;

-- By using the %TYPE of the column we ensure that
-- the parameter will update if the table column does



CREATE FUNCTION customer.create_user(
	  username core.user.username%TYPE
	, password TEXT
) RETURNS core.user.id%TYPE AS $$
	-- Normally we would check that the user
	-- has permission to create a user here.
	INSERT INTO core.user (username, password)
	VALUES (
		  create_user.username -- Personally I prefer to use this syntax over $1
		, core.encode_password("password" := create_user.password)
	) RETURNING id ;
$$ LANGUAGE SQL SECURITY DEFINER ; -- SECURITY DEFINER means that the function will run with the current priviledges.

DELETE FROM core.user ; -- Lets just clean up our old data ;

-- Now we can call the function like so:
SELECT customer.create_user("username" := 'Testy McTesterson', "password" := 't35Ty !s 1337');

