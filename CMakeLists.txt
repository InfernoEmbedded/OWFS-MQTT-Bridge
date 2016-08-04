#set to minimum version that supports clean build on cygwin
cmake_minimum_required(VERSION 2.8.4)

project(uchisan)

include(ExternalProject)

ExternalProject_Add(Mosquitto
	PREFIX dependencies
	GIT_REPOSITORY https://github.com/eclipse/mosquitto.git
	GIT_TAG v1.4.9
	CMAKE_ARGS -DCMAKE_INSTALL_PREFIX=${CMAKE_CURRENT_SOURCE_DIR}/deps -DWITH_WEBSOCKETS=ON
# The man pages don't build on fedora, so we'll just create dummies to allow the install target to run
	PATCH_COMMAND touch ${CMAKE_CURRENT_SOURCE_DIR}/dependencies/src/Mosquitto/man/mosquitto_passwd.1
		${CMAKE_CURRENT_SOURCE_DIR}/dependencies/src/Mosquitto/man/mosquitto_pub.1
		${CMAKE_CURRENT_SOURCE_DIR}/dependencies/src/Mosquitto/man/mosquitto_sub.1
		${CMAKE_CURRENT_SOURCE_DIR}/dependencies/src/Mosquitto/man/libmosquitto.3
		${CMAKE_CURRENT_SOURCE_DIR}/dependencies/src/Mosquitto/man/mosquitto.conf.5
		${CMAKE_CURRENT_SOURCE_DIR}/dependencies/src/Mosquitto/man/mosquitto.8
		${CMAKE_CURRENT_SOURCE_DIR}/dependencies/src/Mosquitto/man/mosquitto-tls.7
		${CMAKE_CURRENT_SOURCE_DIR}/dependencies/src/Mosquitto/man/mqtt.7
)

file(DOWNLOAD https://code.jquery.com/jquery-3.1.0.min.js ${CMAKE_CURRENT_SOURCE_DIR}/webroot/jquery/jquery.min.js)
file(DOWNLOAD http://malsup.github.com/min/jquery.form.min.js ${CMAKE_CURRENT_SOURCE_DIR}/webroot/jquery/jquery.form.min.js)

file(DOWNLOAD https://jqueryui.com/resources/download/jquery-ui-1.12.0.zip
	${CMAKE_CURRENT_SOURCE_DIR}/dependencies/jquery-ui-1.12.0.zip
	EXPECTED_HASH SHA1=37d5f1eed505bda8e3ee23e2acf2b19d4166bd44)
execute_process(COMMAND
	unzip -o ${CMAKE_CURRENT_SOURCE_DIR}/dependencies/jquery-ui-1.12.0.zip -d ${CMAKE_CURRENT_SOURCE_DIR}/dependencies)
file(REMOVE_RECURSE ${CMAKE_CURRENT_SOURCE_DIR}/webroot/jquery-ui)
file(RENAME ${CMAKE_CURRENT_SOURCE_DIR}/dependencies/jquery-ui-1.12.0 ${CMAKE_CURRENT_SOURCE_DIR}/webroot/jquery-ui)

file(DOWNLOAD https://www.eclipse.org/downloads/download.php?file=/paho/releases/1.0.2/paho.javascript-1.0.2.zip&r=1
	${CMAKE_CURRENT_SOURCE_DIR}/dependencies/paho.javascript-1.0.2.zip
	EXPECTED_HASH SHA1=b6a09ce079a21f9eed8aaa3db074193b9dfa5e2c)
execute_process(COMMAND
	unzip -o ${CMAKE_CURRENT_SOURCE_DIR}/dependencies/paho.javascript-1.0.2.zip -d ${CMAKE_CURRENT_SOURCE_DIR}/dependencies)
file(REMOVE_RECURSE ${CMAKE_CURRENT_SOURCE_DIR}/webroot/paho)
file(RENAME ${CMAKE_CURRENT_SOURCE_DIR}/dependencies/paho.javascript-1.0.2 ${CMAKE_CURRENT_SOURCE_DIR}/webroot/paho)

