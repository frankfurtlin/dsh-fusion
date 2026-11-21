package top.frankfurtlin.dshfusion.bridge;

import java.io.UnsupportedEncodingException;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.URLDecoder;
import java.util.HashMap;
import java.util.Map;

/**
 * Parses the pairing deep link that the DSH web UI renders as a QR code:
 *
 * <pre>dshmobile://pair?v=1&amp;e=https%3A%2F%2Fdsh.example.com[&amp;i=1]</pre>
 *
 * {@code e} is the percent-encoded server origin; {@code i=1} is set by the web
 * UI when the origin is plain HTTP (the server is its own CA / LAN-only),
 * mirroring the "允许 HTTP / 自签证书" opt-in on the setup screen. The opt-in is
 * still enforced by the caller, so a link alone can never weaken TLS policy.
 *
 * Pure JDK on purpose (no {@code android.net.Uri}): the same class is covered by
 * JVM tests ({@code PairLinkTest}) and by the manifest contract that a camera
 * scan opens the app on {@code dshmobile://pair}.
 */
public final class PairLink {
  public static final String SCHEME = "dshmobile";
  public static final String HOST = "pair";
  public static final int VERSION = 1;

  /** Validated server origin (no trailing slash, no path). */
  public final Endpoint endpoint;
  /** True when the link itself declares the origin as plain HTTP. */
  public final boolean insecure;

  private PairLink(Endpoint endpoint, boolean insecure) {
    this.endpoint = endpoint;
    this.insecure = insecure;
  }

  /**
   * @return the parsed link, or {@code null} when the input is not a well-formed
   *     pairing link for a supported version. Callers treat null as "not ours".
   */
  public static PairLink parse(String raw) {
    if (raw == null) return null;
    URI uri;
    try {
      uri = new URI(raw.trim());
    } catch (URISyntaxException e) {
      return null;
    }
    if (uri.getScheme() == null || !SCHEME.equalsIgnoreCase(uri.getScheme())) return null;
    String host = uri.getHost();
    if (host == null || !HOST.equalsIgnoreCase(host)) return null;
    // `dshmobile://someone@pair?...` is not a link we generate; userinfo is refused.
    if (uri.getUserInfo() != null || (uri.getRawAuthority() != null && uri.getRawAuthority().indexOf('@') >= 0)) return null;
    // A pairing link carries its data in the query only; refuse path/fragment so a
    // link cannot smuggle anything else into the hand-off.
    if (uri.getPath() != null && !uri.getPath().isEmpty() && !uri.getPath().equals("/")) return null;
    if (uri.getRawFragment() != null) return null;

    Map<String, String> query = parseQuery(uri.getRawQuery());
    String version = query.get("v");
    if (version == null) version = String.valueOf(VERSION); // links without `v` are v1
    if (!String.valueOf(VERSION).equals(version)) return null;

    String origin = query.get("e");
    if (origin == null || origin.isEmpty()) return null;

    URI target;
    try {
      target = new URI(origin);
    } catch (URISyntaxException e) {
      return null;
    }
    // Only a bare origin is acceptable: no path (beyond "/"), query, fragment or userinfo.
    String path = target.getPath();
    if (path != null && !path.isEmpty() && !path.equals("/")) return null;
    if (target.getRawQuery() != null || target.getRawFragment() != null) return null;
    String authority = target.getRawAuthority();
    if (authority == null || authority.indexOf('@') >= 0) return null;

    Endpoint endpoint = Endpoint.parse(origin);
    if (endpoint == null) return null;
    return new PairLink(endpoint, "1".equals(query.get("i")));
  }

  /** True when this string looks like a pairing link at all (used to ignore other intents). */
  public static boolean matches(String raw) {
    if (raw == null) return false;
    String trimmed = raw.trim().toLowerCase(java.util.Locale.ROOT);
    return trimmed.startsWith(SCHEME + "://" + HOST);
  }

  /**
   * Parses whatever the in-app scanner returned: either the pairing deep link or a bare
   * server URL (people sometimes scan a plain {@code https://…} link instead). The caller
   * still enforces the plain-HTTP opt-in, exactly like {@link #parse}.
   */
  public static Scanned parseScan(String raw) {
    if (raw == null) return null;
    String text = raw.trim();
    if (text.isEmpty()) return null;
    PairLink link = parse(text);
    if (link != null) return new Scanned(link.endpoint, link.insecure);
    Endpoint endpoint = Endpoint.parse(text);
    if (endpoint == null) return null;
    return new Scanned(endpoint, false);
  }

  /** Result of {@link #parseScan}: a validated endpoint plus the link's plain-HTTP flag. */
  public static final class Scanned {
    public final Endpoint endpoint;
    public final boolean insecure;

    Scanned(Endpoint endpoint, boolean insecure) {
      this.endpoint = endpoint;
      this.insecure = insecure;
    }
  }

  private static Map<String, String> parseQuery(String rawQuery) {
    Map<String, String> values = new HashMap<>();
    if (rawQuery == null || rawQuery.isEmpty()) return values;
    for (String pair : rawQuery.split("&")) {
      if (pair.isEmpty()) continue;
      int eq = pair.indexOf('=');
      String key = eq < 0 ? pair : pair.substring(0, eq);
      String value = eq < 0 ? "" : pair.substring(eq + 1);
      // '+' is a literal plus in percent-encoding here, never a space (origins never
      // contain spaces; the web UI emits %XX for everything else).
      values.put(decode(key), decode(value));
    }
    return values;
  }

  private static String decode(String value) {
    try {
      return URLDecoder.decode(value.replace("+", "%2B"), "UTF-8");
    } catch (UnsupportedEncodingException | IllegalArgumentException e) {
      return value;
    }
  }
}
