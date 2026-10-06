// Copyright 2026 Bloomberg Finance L.P.
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <mqbmock_dispatcher.h>

#include <bmqtst_testhelper.h>

#include <bsl_iostream.h>
#include <bslmt_threadutil.h>

using namespace BloombergLP;
using namespace bsl;

namespace {

static void test1_executor()
{
    bmqtst::TestHelper::printTestName("MOCK DISPATCHER EXECUTOR");

    bslma::Allocator*         allocator = bmqtst::TestHelperUtil::allocator();
    mqbmock::Dispatcher       dispatcher(allocator);
    mqbmock::DispatcherClient client(allocator);
    dispatcher.registerClient(&client, mqbi::DispatcherClientType::e_CLUSTER);
    bmqex::Executor executor = dispatcher.executor(&client);

    const bslmt::ThreadUtil::Id callingThread = bslmt::ThreadUtil::selfId();
    int                         callCount     = 0;
    const mqbi::Dispatcher::VoidFunction callback = [&]() {
        BMQTST_ASSERT(
            bslmt::ThreadUtil::areEqual(callingThread,
                                        bslmt::ThreadUtil::selfId()));
        ++callCount;
    };

    executor.post(callback);
    BMQTST_ASSERT_EQ(callCount, 1);
    executor.dispatch(callback);
    BMQTST_ASSERT_EQ(callCount, 2);

    dispatcher.setEnqueueOnly(true);
    executor.post(callback);
    executor.dispatch(callback);
    BMQTST_ASSERT_EQ(callCount, 2);
    dispatcher.processQueue();
    BMQTST_ASSERT_EQ(callCount, 4);

    dispatcher.setEnqueueOnly(false);
    dispatcher.unregisterClient(&client);
    executor.post(callback);
    BMQTST_ASSERT_EQ(callCount, 5);
}

}  // close unnamed namespace

int main(int argc, char* argv[])
{
    TEST_PROLOG(bmqtst::TestHelper::e_DEFAULT);

    switch (_testCase) {
    case 0:
    case 1: test1_executor(); break;
    default: {
        cerr << "WARNING: CASE '" << _testCase << "' NOT FOUND." << endl;
        bmqtst::TestHelperUtil::testStatus() = -1;
    } break;
    }

    TEST_EPILOG(bmqtst::TestHelper::e_DEFAULT);
}
