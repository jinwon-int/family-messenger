// Capability test only, no keys or messaging state.
postMessage({credentialsAvailable:typeof navigator.credentials!=='undefined',secureContext:isSecureContext});
