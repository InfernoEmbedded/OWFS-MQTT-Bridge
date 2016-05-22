#set to minimum version that supports clean build on cygwin
cmake_minimum_required(VERSION 2.8.4)

project(homeautomation)

include(ExternalProject)

ExternalProject_Add(Mosquitto
	PREFIX dependencies
	GIT_REPOSITORY https://github.com/eclipse/mosquitto.git
	GIT_TAG v1.4.8
	CMAKE_ARGS -DCMAKE_INSTALL_PREFIX=${CMAKE_CURRENT_SOURCE_DIR}/deps
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