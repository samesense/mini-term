// Copyright 2026 MiniTerm contributors. GPL-3.0-or-later; see COPYING.
// Native embedding of the upstream Mosh transport and terminal state model.
// No process signal handlers, global locale changes, stdio redirection or job control.
#include "include/MoshNative.h"
#include "src/network/networktransport-impl.h"
#include "src/statesync/completeterminal.h"
#include "src/statesync/user.h"
#include "src/util/timestamp.h"
#include <arpa/inet.h>
#include <poll.h>
#include <xlocale.h>
#include <atomic>
#include <mutex>
#include <string>
#include <algorithm>
#include <chrono>
#include <vector>

struct MTMosh {
  std::string ip, key, port;
  std::mutex mutex;
  std::string pending;
  uint16_t columns, rows;
  bool resized = true;
  std::atomic<bool> stopped{false}, paused{false};
  MTMosh(const char *ip_, uint16_t p, const char *k, uint16_t c, uint16_t r)
      : ip(ip_), key(k), port(std::to_string(p)), columns(c), rows(r) {}
  ~MTMosh() { std::fill(key.begin(), key.end(), '\0'); }
};
MTMosh *mt_mosh_create(const char *ip, uint16_t port, const char *key, uint16_t c, uint16_t r) {
  unsigned char address[16];
  if (!ip || !key || !port || !c || !r || strlen(key) != 22 ||
      (!inet_pton(AF_INET, ip, address) && !inet_pton(AF_INET6, ip, address))) return nullptr;
  for (size_t i=0; i<22; i++) if (!isalnum((unsigned char)key[i]) && key[i]!='+' && key[i]!='/') return nullptr;
  try { return new MTMosh(ip, port, key, c, r); } catch (...) { return nullptr; }
}
int mt_mosh_send(MTMosh *c, const uint8_t *bytes, size_t count) {
  if (!c || (!bytes && count) || c->stopped) return 0;
  std::lock_guard<std::mutex> lock(c->mutex);
  if (count > 1024*1024 - c->pending.size()) return 0;
  if (count) c->pending.append((const char*)bytes, count);
  return 1;
}
void mt_mosh_resize(MTMosh *c, uint16_t cols, uint16_t rows) {
  if (!c || !cols || !rows) return;
  std::lock_guard<std::mutex> lock(c->mutex);
  c->columns=cols; c->rows=rows; c->resized=true;
}
void mt_mosh_pause(MTMosh *c, int paused) { if(c) c->paused = paused != 0; }
void mt_mosh_stop(MTMosh *c) { if(c) c->stopped=true; }
void mt_mosh_destroy(MTMosh *c) { delete c; }
int mt_mosh_run(MTMosh *c, void *ctx, MTMoshOutput output, MTMoshStatus status) {
  if (!c || !output || !status) return 1;
  // Physical iPadOS ships Darwin's encoding locale, not macOS's regional
  // en_US.UTF-8 locale data. Keep this thread-local; do not change app locale.
  locale_t utf8 = newlocale(LC_CTYPE_MASK, "UTF-8", nullptr);
  if (!utf8) return 4;
  locale_t previous = uselocale(utf8);
  int result = 1;
  try {
    freeze_timestamp();
    uint16_t columns, rows;
    { std::lock_guard<std::mutex> lock(c->mutex); columns=c->columns; rows=c->rows; }
    Network::UserStream blank;
    Terminal::Complete terminal(columns, rows);
    Network::Transport<Network::UserStream, Terminal::Complete> network(blank, terminal,
      c->key.c_str(), c->ip.c_str(), c->port.c_str());
    network.set_send_delay(1);
    Terminal::Display display(false);
    Terminal::Framebuffer local(columns, rows);
    bool connected=false, rendered=false, stalled=false;
    auto started=std::chrono::steady_clock::now(), stopping=started;
    auto lastPacket=started;
    bool shutdown=false;
    auto emit=[&](const std::string &s) { if (!s.empty()) output(ctx, (const uint8_t*)s.data(), s.size()); };
    emit(display.open());
    while (true) {
      freeze_timestamp();
      const auto now=std::chrono::steady_clock::now();
      if(c->stopped && !shutdown) { shutdown=true; stopping=now; network.start_shutdown(); }
      if(shutdown && now-stopping > std::chrono::seconds(1)) { result=2; break; }
      if(!connected && now-started > std::chrono::seconds(15)) { result=3; break; }
      if(connected && !stalled && now-lastPacket > std::chrono::seconds(3)) { stalled=true; status(ctx,2); }
      {
        std::lock_guard<std::mutex> lock(c->mutex);
        if (!shutdown) {
          if(c->resized && network.get_current_state().size() < 65536) {
            network.get_current_state().push_back(Parser::Resize(c->columns,c->rows)); c->resized=false;
          }
          // Bound both the producer queue and unacknowledged protocol history while
          // offline. Drain in order as acknowledgements free space; never replay writes.
          const size_t capacity = 65536 - std::min(size_t(65536), network.get_current_state().size());
          const size_t count = std::min(capacity, c->pending.size());
          for(size_t i=0; i<count; i++) network.get_current_state().push_back(Parser::UserByte((unsigned char)c->pending[i]));
          c->pending.erase(0,count);
        }
        if(shutdown) c->pending.clear();
      }
      // Temporary route/socket failures are normal during roaming. Keep the transport
      // and its encrypted state alive; upstream will retry from the new interface.
      try { network.tick(); } catch(const Network::NetworkException &) {}
      if(network.get_remote_state_num()!=0) {
        if(!connected) { connected=true; status(ctx,1); }
        if(!c->paused) {
          const auto &frame=network.get_latest_remote_state().state.get_fb();
          emit(display.new_frame(rendered,local,frame)); local=frame; rendered=true;
        }
      }
      if(network.counterparty_shutdown_ack_sent() || (network.shutdown_in_progress() && network.shutdown_acknowledged())) {
        result=c->stopped ? 2 : 0; break;
      }
      std::vector<pollfd> fds;
      for(int fd: network.fds()) fds.push_back({fd,POLLIN,0});
      int wait=std::max(0,std::min(20,network.wait_time()));
      int ready=poll(fds.data(),fds.size(),wait);
      freeze_timestamp();
      if(ready<0 && errno!=EINTR) break;
      for(auto &fd:fds) if(fd.revents&POLLIN) {
        try {
          network.recv(); lastPacket=std::chrono::steady_clock::now();
          if(stalled) { stalled=false; status(ctx,3); }
        } catch(const Network::NetworkException &) {} catch(const Crypto::CryptoException &e) { if(e.fatal) throw; }
        break;
      }
    }
    // This surface belongs to the app rather than an enclosing local shell.
    // Retain the final screen for inspection/copying; a reconnect gets a fresh surface.
  } catch (...) { result=1; } // Never expose keys, payloads or exception contents in app diagnostics.
  uselocale(previous); freelocale(utf8);
  return result;
}
