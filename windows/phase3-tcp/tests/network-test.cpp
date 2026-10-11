// Integration tests use the production queue, framing, and network thread.
// No Raw Input registration, cursor lock, display switching or real pair file.
#define wmain TraiectusApplicationMain
#ifndef TRAIECTUS_SERVER_SOURCE
#define TRAIECTUS_SERVER_SOURCE "../src/main.cpp"
#endif
#include TRAIECTUS_SERVER_SOURCE
#undef wmain
#include <chrono>
#include <stdexcept>
#include <numeric>

void Check(bool ok, const char* what) {
    if (!ok) throw std::runtime_error(what);
    std::printf("PASS: %s\n", what);
}
void Require(bool ok, const char* what) {
    if (!ok) throw std::runtime_error(what);
}
template<class Predicate> bool Eventually(Predicate p, DWORD ms = 1500) {
    const ULONGLONG end = GetTickCount64() + ms;
    do { if (p()) return true; Sleep(2); } while (GetTickCount64() < end);
    return p();
}

struct Peer {
    SOCKET sock = INVALID_SOCKET;
    std::string buffer;
    explicit Peer(unsigned short port) {
        sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        sockaddr_in addr{}; addr.sin_family=AF_INET;
        addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK); addr.sin_port=htons(port);
        Require(connect(sock,(sockaddr*)&addr,sizeof(addr)) == 0, "connect loopback");
        DWORD timeout=5000;
        setsockopt(sock,SOL_SOCKET,SO_RCVTIMEO,(char*)&timeout,sizeof(timeout));
        BOOL yes=TRUE; setsockopt(sock,IPPROTO_TCP,TCP_NODELAY,(char*)&yes,sizeof(yes));
    }
    ~Peer() { if(sock!=INVALID_SOCKET) closesocket(sock); }
    void Send(const std::string& s) {
        size_t n=0;
        while(n<s.size()) { int got=send(sock,s.data()+n,(int)(s.size()-n),0);
            Require(got>0,"peer send"); n+=(size_t)got; }
    }
    std::string Line(bool replyPing = true) {
        for (;;) {
            auto nl=buffer.find('\n');
            if(nl!=std::string::npos) {
                auto line=buffer.substr(0,nl); buffer.erase(0,nl+1);
                if(replyPing && line.rfind("PING ",0)==0) {Send("PONG "+line.substr(5)+"\n"); continue;}
                return line;
            }
            char bytes[16384];int got=recv(sock,bytes,sizeof(bytes),0);
            Require(got>0,"peer receive line");buffer.append(bytes,(size_t)got);
        }
    }
    void Hello() {
        Send("HELLO 1 Mac network-test-only\n");
        Require(Line()=="HELLO-OK 1", "handshake reply");
        Require(Line()=="MODE Win", "initial Windows mode");
    }
};

struct Fixture {
    std::thread thread;
    unsigned short port=0;
    Fixture() {
        WSADATA data{}; Require(WSAStartup(MAKEWORD(2,2),&data)==0,"WSAStartup");
        QueryPerformanceFrequency(&g_qpcFreq);
        g_running=true; g_macMode=false; g_opts.maxQueue=kDefaultQueueLines;
        wchar_t temp[MAX_PATH]; GetTempPathW(MAX_PATH,temp);
        g_opts.pairFile=std::wstring(temp)+L"traiectus-network-test-"+std::to_wstring(GetCurrentProcessId())+L".pair";
        Require(WritePairFileToken("network-test-only"),"isolated pair file");
        g_listener=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
        sockaddr_in addr{};addr.sin_family=AF_INET;addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
        Require(bind(g_listener,(sockaddr*)&addr,sizeof(addr))==0,"bind test listener");
        Require(listen(g_listener,4)==0,"listen test listener");
        int size=sizeof(addr); getsockname(g_listener,(sockaddr*)&addr,&size);port=ntohs(addr.sin_port);
        u_long yes=1;ioctlsocket(g_listener,FIONBIO,&yes);
#ifndef TRAIECTUS_POLLING_BASELINE
        Require(InitializeNetworkWake(),"initialize queue events");
#endif
        thread=std::thread(NetworkThread);
    }
    void Stop() {
        if(!thread.joinable()) return;
        g_running=false;
#ifndef TRAIECTUS_POLLING_BASELINE
        SetEvent(g_networkStop);
#endif
        thread.join(); closesocket(g_listener);g_listener=INVALID_SOCKET;
#ifndef TRAIECTUS_POLLING_BASELINE
        DestroyNetworkWake();
#endif
        DeleteFileW(g_opts.pairFile.c_str());WSACleanup();
    }
    ~Fixture(){Stop();}
};

#ifndef TRAIECTUS_POLLING_BASELINE
void BackpressureTest() {
    SOCKET listener=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
    sockaddr_in addr{};addr.sin_family=AF_INET;addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    Require(bind(listener,(sockaddr*)&addr,sizeof(addr))==0,"backpressure bind");
    listen(listener,1);int len=sizeof(addr);getsockname(listener,(sockaddr*)&addr,&len);
    Peer peer(ntohs(addr.sin_port));Client client;client.sock=accept(listener,nullptr,nullptr);closesocket(listener);
    int small=1024;setsockopt(client.sock,SOL_SOCKET,SO_SNDBUF,(char*)&small,sizeof(small));
    client.socketEvent=WSACreateEvent();
    Require(WSAEventSelect(client.sock,client.socketEvent,FD_WRITE|FD_CLOSE)==0,"backpressure event registration");
    ClearOutputQueue();std::string line(240,'x');
    const size_t total=5000*(line.size()+1);
    for(int i=0;i<5000;i++) EnqueueLine(line);
    for(int i=0;i<20 && !client.writeBlocked && HasClientOutput(client);i++)
        Require(FlushOutput(client),"backpressure initial flush");
    Check(client.writeBlocked,"full socket reports blocked send");
    std::atomic<size_t> received{0};
    std::thread reader([&]{char buf[16384];while(received<total){int n=recv(peer.sock,buf,sizeof(buf),0);if(n<=0)break;received+=(size_t)n;}});
    const auto end=GetTickCount64()+15000;
    bool valid=true;
    while(HasClientOutput(client) && GetTickCount64()<end) {
        if(client.writeBlocked) {
            DWORD wait=WSAWaitForMultipleEvents(1,&client.socketEvent,FALSE,1000,FALSE);
            if(wait==WSA_WAIT_FAILED) {valid=false;break;}
            WSANETWORKEVENTS ev{};WSAEnumNetworkEvents(client.sock,client.socketEvent,&ev);
            if(ev.lNetworkEvents&FD_WRITE) client.writeBlocked=false;
        }
        if(!client.writeBlocked && !FlushOutput(client)) {valid=false;break;}
    }
    if(HasClientOutput(client) || !valid) shutdown(peer.sock,SD_BOTH);
    reader.join();
    const bool empty=!HasClientOutput(client);
    closesocket(client.sock);WSACloseEvent(client.socketEvent);ClearOutputQueue();
    Check(valid && empty && received==total,"FD_WRITE resumes partial output without loss");
}
#endif

void Benchmark(Peer& peer) {
    std::vector<double> latency;
    Sleep(100); // let the network thread actually enter its idle wait
    for(int i=0;i<200;i++) {
        Sleep(7);g_sendLatencyMaxMs=0;
        const std::string message="MOVE "+std::to_string(i)+" 1";
        EnqueueLine(message);
        Require(peer.Line()==message,"benchmark event order");
        latency.push_back(g_sendLatencyMaxMs.load());
    }
    std::sort(latency.begin(),latency.end());
    std::printf("BENCHMARK: samples=%zu send_ms median=%.3f p95=%.3f max=%.3f\n",
        latency.size(),latency[latency.size()/2],latency[(latency.size()-1)*95/100],latency.back());
}

int wmain(int argc,wchar_t** argv) {
    try {
        Fixture fixture;
        if(argc>1 && std::wstring(argv[1])==L"--benchmark") {
            Peer peer(fixture.port);peer.Hello();Benchmark(peer);return 0;
        }
#ifndef TRAIECTUS_POLLING_BASELINE
        {Client partial;partial.currentLine="MOVE 1 2\n";partial.currentOffset=3;
            Check(HasClientOutput(partial),"partially sent line counts as pending output");
            partial.sock=(SOCKET)1;partial.closeAfterFlush=true;
            partial.lastPing=0;partial.closeDeadline=GetTickCount64()+1000;
            Check(NetworkWaitTimeout(partial)>100,"closing wait ignores expired heartbeat");}
        {Peer wrong(fixture.port);wrong.Send("HELLO 1 Mac wrong\n");
            Check(wrong.Line()=="ERR AUTH","authentication error is flushed before close");}
        Require(Eventually([]{return !g_clientPresent.load();}),"auth client closes");
        {
            Peer peer(fixture.port);peer.Hello();Check(g_clientReady,"authenticated handshake succeeds");
            EnqueueLine("MOVE 1 2");Check(peer.Line()=="MOVE 1 2","enqueue wakes an idle socket");
            for(int i=0;i<1400;i++)EnqueueLine("MOVE "+std::to_string(i)+" 2");
            for(int i=0;i<1400;i++)Require(peer.Line()=="MOVE "+std::to_string(i)+" 2","burst order");
            Check(true,"batch boundary drains 1400 events in order");
            for(auto line:{"DOWN L","MOVE 2 3","UP L","WHEEL 120","HWHEEL -120"}) {
                EnqueueLine(line);Require(peer.Line()==line,"button/wheel order");}
            Check(true,"button drag and wheel messages preserve order");
            peer.Send("PING 123\n");Check(peer.Line()=="PONG 123","heartbeat response wakes output");
            {Peer replacement(fixture.port);replacement.Hello();Check(g_clientReady,"replacement client reconnects");}
        }
        Require(Eventually([]{return !g_clientPresent.load();}),"peer EOF closes socket");
        BackpressureTest();
        {
            Peer peer(fixture.port);peer.Hello();g_opts.maxQueue=0;EnqueueLine("MOVE 1 1");
            Check(Eventually([]{return !g_clientPresent.load();}),"queue overflow disconnects safely");
            g_opts.maxQueue=kDefaultQueueLines;
        }
        {
            Peer peer(fixture.port);peer.Hello();
            Check(Eventually([]{return !g_clientPresent.load();},4500),"silent peer expires after heartbeat timeout");
        }
        {Peer peer(fixture.port);peer.Hello();Check(g_clientReady,"connection recovers after timeout");}
        Require(Eventually([]{return !g_clientPresent.load();}),"final peer closes");
        auto start=GetTickCount64();fixture.Stop();
        Check(GetTickCount64()-start<500,"stop wakes an idle listener");
        std::printf("NETWORK TESTS PASSED\n");
#endif
        return 0;
    } catch(const std::exception& e) {
        std::fprintf(stderr,"FAIL: %s\n",e.what());return 1;
    }
}
