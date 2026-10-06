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

#include <mqbblp_cluster.h>

#include <mqbc_clusterutil.h>
#include <mqbcfg_brokerconfig.h>
#include <mqbmock_cluster.h>
#include <mqbmock_dispatcher.h>
#include <mqbnet_mockcluster.h>
#include <mqbstat_clusterstats.h>

#include <bmqex_sequentialcontext.h>
#include <bmqio_testchannel.h>
#include <bmqp_event.h>
#include <bmqp_schemaeventbuilder.h>
#include <bmqst_statcontext.h>
#include <bmqtst_testhelper.h>
#include <bmqu_tempdirectory.h>

#include <bsl_iostream.h>
#include <bsl_memory.h>
#include <bsl_unordered_map.h>
#include <bslma_managedptr.h>

using namespace BloombergLP;
using namespace bsl;

namespace {

static void rejectPeerAdminCommand(bool                     isFSMWorkflow,
                                   bmqp::EncodingType::Enum encoding)
{
    bslma::Allocator*   allocator = bmqtst::TestHelperUtil::allocator();
    bmqu::TempDirectory tempDir(allocator);
    mqbmock::Cluster::ClusterNodeDefs nodes(allocator);
    mqbc::ClusterUtil::appendClusterNode(&nodes,
                                         "testNode1",
                                         "test",
                                         41234,
                                         1,
                                         allocator);
    mqbc::ClusterUtil::appendClusterNode(&nodes,
                                         "testNode2",
                                         "test",
                                         41235,
                                         2,
                                         allocator);

    mqbmock::Cluster                   backing(allocator,
                             true,
                             false,
                             isFSMWorkflow,
                             false,
                             nodes,
                             "testCluster",
                             tempDir.path());
    const mqbi::ClusterResources&      resources = backing._resources();
    bslma::ManagedPtr<mqbnet::Cluster> netCluster(
        new (*allocator) mqbnet::MockCluster(backing._clusterDefinition(),
                                             resources.bufferFactory(),
                                             allocator),
        allocator);
    static_cast<mqbnet::MockCluster*>(netCluster.get())->_setSelfNodeId(2);
    mqbnet::ClusterNode*                peer = netCluster->lookupNode(1);
    bsl::shared_ptr<bmqio::TestChannel> channel =
        bsl::allocate_shared<bmqio::TestChannel>(allocator);
    peer->setChannel(channel,
                     bmqp_ctrlmsg::ClientIdentity(),
                     bmqio::Channel::ReadCallback());

    bsl::shared_ptr<bmqst::StatContext> stats =
        mqbstat::ClusterStatsUtil::initializeStatContextCluster(2, allocator);
    bsl::unordered_map<bsl::string, bmqst::StatContext*> statContexts(
        allocator);
    statContexts["clusters"]     = stats.get();
    statContexts["clusterNodes"] = stats.get();

    bmqex::SequentialContext dispatcherContext(allocator);
    BMQTST_ASSERT_EQ(dispatcherContext.start(), 0);
    const bmqex::Executor dispatcherExecutor = dispatcherContext.executor();
    mqbmock::Dispatcher   dispatcher(dispatcherExecutor, allocator);
    int                   callbackCount = 0;
    mqbnet::Session::AdminCommandEnqueueCb adminCb =
        [&callbackCount](const bsl::string&,
                         const bsl::string&,
                         const mqbnet::Session::AdminCommandProcessedCb&,
                         bool) {
            ++callbackCount;
        };
    mqbblp::Cluster cluster("testCluster",
                            backing._clusterDefinition(),
                            netCluster,
                            statContexts,
                            backing._clusterData()->domainFactory(),
                            &dispatcher,
                            backing._clusterData()->transportManager(),
                            0,
                            resources,
                            allocator,
                            adminCb);

    bmqp_ctrlmsg::ControlMessage request(allocator);
    request.rId()                                 = 1;
    request.choice().makeAdminCommand().command() = "HELP";
    bmqp::SchemaEventBuilder builder(resources.blobSpPool(),
                                     encoding,
                                     allocator);
    BMQTST_ASSERT_EQ(builder.setMessage(request, bmqp::EventType::e_CONTROL),
                     0);
    bmqp::Event event(builder.blob().get(), allocator);
    cluster.processEvent(event, peer);

    BMQTST_ASSERT_EQ(callbackCount, 0);
    BMQTST_ASSERT_EQ(channel->numWriteCalls(), 0U);
}

static void test1_rejectPeerAdminCommand()
{
    bmqtst::TestHelper::printTestName("REJECT PEER ADMIN COMMAND");

    rejectPeerAdminCommand(false, bmqp::EncodingType::e_BER);
    rejectPeerAdminCommand(false, bmqp::EncodingType::e_JSON);
    rejectPeerAdminCommand(true, bmqp::EncodingType::e_BER);
    rejectPeerAdminCommand(true, bmqp::EncodingType::e_JSON);
}

}  // close unnamed namespace

int main(int argc, char* argv[])
{
    TEST_PROLOG(bmqtst::TestHelper::e_DEFAULT);

    mqbcfg::AppConfig brokerConfig(bmqtst::TestHelperUtil::allocator());
    mqbcfg::BrokerConfig::set(brokerConfig);

    switch (_testCase) {
    case 0:
    case 1: test1_rejectPeerAdminCommand(); break;
    default: {
        cerr << "WARNING: CASE '" << _testCase << "' NOT FOUND." << endl;
        bmqtst::TestHelperUtil::testStatus() = -1;
    } break;
    }

    TEST_EPILOG(bmqtst::TestHelper::e_DEFAULT);
}
