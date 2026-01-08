# Design: simplify-chromecast-connectivity

## Architectural Context

### Current Architecture (Problematic)

```
User clicks Chromecast → showPromoOnChromecast()
                              │
                              ▼
                    ┌─────────────────────┐
                    │ Address Validation  │ ← hasValidAddress check
                    │   (NWConnection)    │
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │ HTTP Reachability   │ ← URLSession to port 8008
                    │   (URLSession)      │   FAILS: "offline" error
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │ TLS Connection      │ ← NWConnection to port 8009
                    │   (NWConnection)    │   Never reached due to above
                    └─────────────────────┘
```

**Problem**: Two different networking stacks (URLSession vs NWConnection) with different permission models.

### Proposed Architecture (Simplified)

```
User clicks Chromecast → showPromoOnChromecast()
                              │
                              ▼
                    ┌─────────────────────┐
                    │ Address Validation  │ ← hasValidAddress check
                    │   (String check)    │
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │ TLS Connection      │ ← NWConnection to port 8009
                    │   (NWConnection)    │   10-second timeout
                    └─────────┬───────────┘
                              │
                    ┌─────────┴───────────┐
                    ▼                     ▼
              ┌──────────┐         ┌──────────────┐
              │ Success  │         │ Timeout/Fail │
              │ → Promo  │         │ → Error msg  │
              └──────────┘         └──────────────┘
```

**Benefits**: Single networking stack, consistent permissions, industry-standard approach.

## Design Rationale

### Why Remove HTTP Reachability Check

| Consideration | HTTP Check (Current) | Direct TLS (Proposed) |
|--------------|---------------------|----------------------|
| **Permission model** | URLSession (stricter) | NWConnection (works) |
| **Timeout** | 2 sec HTTP + 10 sec TLS | 10 sec TLS only |
| **Industry standard** | None use this | VLC, PyChromecast, node-castv2 |
| **Failure mode** | "offline" error | Clean timeout |
| **Code complexity** | Higher | Lower |

### Why NWConnection Works But URLSession Doesn't

macOS Local Network Privacy (introduced in macOS 11) treats different networking APIs differently:

1. **NWConnection** (low-level): Used for direct socket connections
   - Triggers permission prompt when connection is established
   - Permission typically granted for apps doing device discovery

2. **URLSession** (high-level): Used for HTTP/HTTPS requests
   - Has stricter permission requirements
   - May fail silently with "offline" error before prompt

Our app already has Local Network permission (for mDNS discovery), but URLSession doesn't inherit this permission.

### Comparison with Reference Implementations

**PyChromecast** (`socket_client.py`):
```python
# Direct socket, no HTTP check
new_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.verify_mode = ssl.CERT_NONE
self.socket = context.wrap_socket(self.socket)
```

**node-castv2** (`client.js`):
```javascript
// Direct TLS, no HTTP check
options.rejectUnauthorized = false;
this.socket = tls.connect(options, function() { ... });
```

**VLC** (`chromecast.h`):
```cpp
// Direct TLS via vlc_tls, no HTTP check
vlc_tls_client_t* p_tls;
vlc_tls_t* p_tls_session;
```

All three use direct TLS connections with self-signed certificate acceptance. None perform HTTP reachability checks.

### Error Handling Strategy

Instead of pre-checking reachability, handle connection failures gracefully:

| Error Condition | Detection | User Message |
|----------------|-----------|--------------|
| Empty address | `hasValidAddress` | "Device address not resolved" |
| Connection timeout | NWConnection 10s timeout | "Could not connect to Chromecast" |
| Connection refused | NWConnection error | "Chromecast not responding" |
| TLS failure | NWConnection error | "Connection failed" |

## Trade-offs

### Pros
- Simpler code, fewer edge cases
- Aligned with industry implementations
- No permission model conflicts
- Faster user experience (no extra HTTP round-trip)

### Cons
- 10-second wait if device is truly offline (vs 2-second HTTP timeout)
- No "fast fail" for unreachable devices

### Mitigation for Cons
- 10 seconds is acceptable - matches PyChromecast's 30-second default
- User can cancel manually if needed
- Discovery already validated device existence via mDNS
