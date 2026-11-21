// Where hosted conversation links live (docs/design/share-links.md). Same level
// as `shareLandingUrl` in share_code/share_link.dart: change the host here, in
// services/share-worker/wrangler.jsonc, and redeploy.

/// The share host. This project runs none, so the reserved `.invalid` TLD is
/// used: links still parse (they keep their shape for share codes), but no
/// request can ever reach a host, and hosted links are not offered.
const shareHostOrigin = 'https://share.invalid';
