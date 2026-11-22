# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# The Linux shell: the helper host (the private Swift helper in a transient systemd user service
# bound to the shell's scope, its handshake, heartbeats and restart limits), single instance,
# user applications in their own scopes, and the Qt 6 shell over it.
cmake_minimum_required(VERSION 3.25)
project(ssm-connect-linux LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
add_compile_options(-Wall -Wextra -Werror)

find_package(Qt6 6.4 REQUIRED COMPONENTS Core DBus Gui Widgets Qml Quick Test)

add_library(ssmconnect_host STATIC
    src/helper_host.cpp
    src/systemd_containment.cpp
    src/single_instance.cpp
    src/user_applications.cpp)
target_include_directories(ssmconnect_host PUBLIC src)
target_link_libraries(ssmconnect_host PUBLIC Qt6::Core Qt6::DBus)

# The shell: the controller that turns actions into helper commands, the Linux platform port, the
# StatusNotifierItem tray, start at sign-in and the QML settings window.
set(SSM_CONNECT_BUILD "dev" CACHE STRING "The build ID shared by the shell and its helper")
add_library(ssmconnect_shell STATIC
    src/shell_controller.cpp
    src/linux_shell_platform.cpp
    src/tray.cpp
    src/startup_registration.cpp)
qt_add_resources(ssmconnect_shell "qml" PREFIX "/" FILES qml/Settings.qml)
target_include_directories(ssmconnect_shell PUBLIC src)
target_link_libraries(ssmconnect_shell PUBLIC ssmconnect_host Qt6::Gui Qt6::Widgets Qt6::Qml Qt6::Quick)

add_executable(ssm-connect src/main.cpp)
target_compile_definitions(ssm-connect PRIVATE SSM_CONNECT_BUILD="${SSM_CONNECT_BUILD}")
target_link_libraries(ssm-connect PRIVATE ssmconnect_shell)
install(TARGETS ssm-connect RUNTIME DESTINATION bin)

enable_testing()
add_executable(fake_helper tests/fake_helper.cpp)
add_executable(scope_probe tests/scope_probe.cpp)
target_link_libraries(scope_probe PRIVATE ssmconnect_host)
add_executable(helper_host_test tests/helper_host_test.cpp)
target_link_libraries(helper_host_test PRIVATE ssmconnect_host Qt6::Test)
target_compile_definitions(helper_host_test PRIVATE
    FAKE_HELPER_PATH="$<TARGET_FILE:fake_helper>" SCOPE_PROBE_PATH="$<TARGET_FILE:scope_probe>")
add_test(NAME helper_host_test COMMAND helper_host_test)
add_executable(shell_test tests/shell_test.cpp)
target_link_libraries(shell_test PRIVATE ssmconnect_shell Qt6::Test)
add_test(NAME shell_test COMMAND shell_test)
