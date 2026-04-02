use Test2::V1 -ipP;
use Test2::IPC;

use IPC::Manager::Test;
IPC::Manager::Test->run_all(protocol => 'MessageFiles');

done_testing;
