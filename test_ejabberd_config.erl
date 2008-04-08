-module(test_ejabberd_config).
-compile(export_all).

%% SEE vhost.cfg and localhost.cfg
start() ->
    test_raw_fetch(),
    test_vhost_fetch().

test_find_includes() ->
    C = [{include,"foobar"},{blah},{include,baz}],
    ["foobar", baz] = sets:to_list(lists:foldl(fun bjc_config:find_includes/2, sets:new(), C)),
    ok.

test_raw_fetch() ->
    foo = ejabberd_config:get_option(vhost, auth_module),
    ok.

test_vhost_fetch() ->
    foo = ejabberd_config:get_option("localhost", auth_module),
    ok.
