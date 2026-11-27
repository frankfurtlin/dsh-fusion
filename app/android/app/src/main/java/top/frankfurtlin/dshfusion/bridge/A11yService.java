package top.frankfurtlin.dshfusion.bridge;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Path;
import android.graphics.Rect;
import android.hardware.HardwareBuffer;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.util.Log;
import android.view.Display;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Automation without root: reads the on-screen tree and drives taps/swipes through
 * the accessibility API. The user must switch this service on in system settings.
 */
public class A11yService extends AccessibilityService {
  private static final String TAG = "DshA11y";
  /** Longest a bridge call waits for a UI operation. */
  private static final long OP_TIMEOUT_MS = 15_000;
  /** Default screenshot budget; the bridge rejects messages above 1 MiB. */
  private static final int DEFAULT_MAX_IMAGE_BYTES = 600_000;
  /** Most nodes walked when looking for a label the system search did not index. */
  private static final int FIND_SCAN_CAP = 2000;
  /** Time the focused field gets to open its input connection before the one retry types. */
  private static final long FOCUS_SETTLE_MS = 100;
  /** Characters of each candidate's label quoted when several edit boxes compete for the focus. */
  private static final int CANDIDATE_LABEL_CHARS = 20;

  static volatile A11yService instance;

  private final Handler main = new Handler(Looper.getMainLooper());

  @Override
  protected void onServiceConnected() {
    instance = this;
    Log.i(TAG, "accessibility service connected");
  }

  @Override
  public void onAccessibilityEvent(AccessibilityEvent event) {
    // The bridge drives automation by request; there is nothing to do per event.
  }

  @Override
  public void onInterrupt() {
    // No continuous feedback to interrupt.
  }

  @Override
  public boolean onUnbind(Intent intent) {
    instance = null;
    return super.onUnbind(intent);
  }

  @Override
  public void onDestroy() {
    instance = null;
    super.onDestroy();
  }

  /** True while the user has this service switched on. */
  public static boolean ready() {
    return instance != null;
  }

  /** Runs `body` on the main thread and waits, because accessibility calls expect it. */
  private <T> T onMain(Callable<T> body) throws Exception {
    if (Looper.myLooper() == Looper.getMainLooper()) return body.call();
    final Object[] result = new Object[1];
    final Exception[] failure = new Exception[1];
    final CountDownLatch done = new CountDownLatch(1);
    main.post(() -> {
      try {
        result[0] = body.call();
      } catch (Exception e) {
        failure[0] = e;
      } finally {
        done.countDown();
      }
    });
    if (!done.await(OP_TIMEOUT_MS, TimeUnit.MILLISECONDS)) throw new IllegalStateException("accessibility call timed out");
    if (failure[0] != null) throw failure[0];
    @SuppressWarnings("unchecked")
    T value = (T) result[0];
    return value;
  }

  /** Visible text/content of the active window, flattened to a node list. */
  public String tree(final int maxNodes) throws Exception {
    return onMain(() -> {
      AccessibilityNodeInfo root = getRootInActiveWindow();
      if (root == null) throw new IllegalStateException("no active window");
      JSONArray nodes = new JSONArray();
      ArrayDeque<AccessibilityNodeInfo> queue = new ArrayDeque<>();
      queue.add(root);
      while (!queue.isEmpty() && nodes.length() < maxNodes) {
        AccessibilityNodeInfo node = queue.poll();
        JSONObject entry = new JSONObject();
        CharSequence text = node.getText();
        CharSequence desc = node.getContentDescription();
        if (text != null && text.length() > 0) entry.put("text", text.toString());
        if (desc != null && desc.length() > 0) entry.put("desc", desc.toString());
        CharSequence hint = node.getHintText();
        if (hint != null && hint.length() > 0) entry.put("hint", hint.toString());
        if (node.getViewIdResourceName() != null) entry.put("id", node.getViewIdResourceName());
        CharSequence cls = node.getClassName();
        if (cls != null) entry.put("class", cls.toString());
        if (node.isClickable()) entry.put("clickable", true);
        if (node.isEditable()) entry.put("editable", true);
        if (node.isScrollable()) entry.put("scrollable", true);
        if (node.isChecked()) entry.put("checked", true);
        Rect bounds = new Rect();
        node.getBoundsInScreen(bounds);
        entry.put("bounds", new JSONArray(new int[] { bounds.left, bounds.top, bounds.right, bounds.bottom }));
        entry.put("center", new JSONArray(new int[] { bounds.centerX(), bounds.centerY() }));
        nodes.put(entry);
        for (int i = 0; i < node.getChildCount(); i++) {
          AccessibilityNodeInfo child = node.getChild(i);
          if (child != null) queue.add(child);
        }
      }
      JSONObject out = new JSONObject();
      CharSequence pkg = root.getPackageName();
      out.put("package", pkg == null ? "" : pkg.toString());
      out.put("count", nodes.length());
      out.put("nodes", nodes);
      return out.toString();
    });
  }

  /** On-screen nodes whose text or content description matches `query`, with the point that taps them. */
  public JSONObject find(final String query, final boolean exact, final int max) throws Exception {
    return onMain(() -> {
      AccessibilityNodeInfo root = getRootInActiveWindow();
      if (root == null) throw new IllegalStateException("no active window");
      final String needle = query.trim().toLowerCase(Locale.ROOT);
      JSONArray nodes = new JSONArray();
      Set<String> seen = new HashSet<>();
      // The system search is the cheap path: it matches text and content description alike.
      List<AccessibilityNodeInfo> found = root.findAccessibilityNodeInfosByText(query);
      if (found != null) {
        for (AccessibilityNodeInfo node : found) {
          if (nodes.length() >= max) break;
          if (matches(node, needle, exact)) addNode(nodes, seen, node);
        }
      }
      // It only covers the active window's cached nodes; a label that is on screen but missing from
      // that index is still reachable by walking the tree ourselves, capped so a huge tree cannot hang.
      if (nodes.length() == 0) {
        ArrayDeque<AccessibilityNodeInfo> queue = new ArrayDeque<>();
        queue.add(root);
        for (int visited = 0; visited < FIND_SCAN_CAP && !queue.isEmpty() && nodes.length() < max; visited++) {
          AccessibilityNodeInfo node = queue.poll();
          if (matches(node, needle, exact)) addNode(nodes, seen, node);
          for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child != null) queue.add(child);
          }
        }
      }
      JSONObject out = new JSONObject();
      out.put("count", nodes.length());
      out.put("nodes", nodes);
      return out;
    });
  }

  /**
   * True when this node's text, content description or hint carries the
   * lower-cased, trimmed needle.
   *
   * The hint is how a drawn screen's input field is labelled: a Flutter text
   * field has no content description, and Android reports its label there, as
   * the name TalkBack reads for an empty edit box (the terminal's 「终端输入」
   * is exactly that). Without it such a field cannot be found at all before it
   * has text.
   */
  private static boolean matches(AccessibilityNodeInfo node, String needle, boolean exact) {
    return matches(node.getText(), needle, exact)
        || matches(node.getContentDescription(), needle, exact)
        || matches(node.getHintText(), needle, exact);
  }

  private static boolean matches(CharSequence value, String needle, boolean exact) {
    if (value == null) return false;
    String text = value.toString().trim();
    return exact ? text.equalsIgnoreCase(needle) : text.toLowerCase(Locale.ROOT).contains(needle);
  }

  /** Appends one node in the `a11y.find` shape, skipping repeats of the same text at the same bounds. */
  private static void addNode(JSONArray nodes, Set<String> seen, AccessibilityNodeInfo node) throws Exception {
    Rect bounds = new Rect();
    node.getBoundsInScreen(bounds);
    CharSequence text = node.getText();
    CharSequence desc = node.getContentDescription();
    CharSequence hint = node.getHintText();
    if (!seen.add(bounds.flattenToString() + '|' + text + '|' + desc)) return;
    JSONObject entry = new JSONObject();
    if (text != null && text.length() > 0) entry.put("text", text.toString());
    if (desc != null && desc.length() > 0) entry.put("desc", desc.toString());
    if (hint != null && hint.length() > 0) entry.put("hint", hint.toString());
    String viewId = node.getViewIdResourceName();
    if (viewId != null) entry.put("view_id", viewId);
    CharSequence cls = node.getClassName();
    if (cls != null) entry.put("class", cls.toString());
    if (node.isEditable()) entry.put("editable", true);
    entry.put("bounds", new JSONArray(new int[] { bounds.left, bounds.top, bounds.right, bounds.bottom }));
    entry.put("x", bounds.centerX());
    entry.put("y", bounds.centerY());
    nodes.put(entry);
  }

  /**
   * Types into the focused text field, the way a soft keyboard would.
   *
   * A drawn screen can keep input focus on a node that takes no text — the terminal's xterm
   * canvas — while its real edit box (a Flutter EditText, hint 「终端输入」) sits unfocused
   * somewhere else on screen. When that happens the screen's only editable node is focused and
   * the text is retried once, after Flutter has had time to open the input connection.
   */
  public JSONObject typeText(final String value) throws Exception {
    JSONObject done = onMain(() -> typeNow(value, true));
    if (done != null) return done;
    return typeAfterFocus(value);
  }

  /**
   * One typing attempt, on the main thread.
   *
   * The focused input node is used first, exactly as before. When that node is missing or not
   * editable, `mayFocus` decides what happens: with a single editable node on the screen it gets
   * ACTION_FOCUS and this returns null, asking the caller for the one delayed retry. Zero or
   * several candidates throw the error the agent sees.
   */
  private JSONObject typeNow(String value, boolean mayFocus) throws Exception {
    AccessibilityNodeInfo root = getRootInActiveWindow();
    if (root == null) throw new IllegalStateException("no active window");
    AccessibilityNodeInfo target = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
    if (target != null && target.isEditable()) {
      if (!setText(target, value)) throw new IllegalStateException("the focused text field refused the text");
      return typed(value);
    }
    List<AccessibilityNodeInfo> candidates = editableNodes(root);
    if (candidates.size() > 1) {
      throw new IllegalStateException("the screen shows " + candidates.size()
          + " editable text fields but none of them has input focus; tap the field itself first: " + describe(candidates));
    }
    if (candidates.isEmpty()) {
      throw new IllegalStateException(target == null
          ? "no text field has input focus; tap the field first"
          : "the focused node is not an editable text field; tap the field itself first");
    }
    AccessibilityNodeInfo field = candidates.get(0);
    if (!mayFocus) {
      // Second pass: typing is all this call gets; the field was already focused on the first.
      if (!setText(field, value)) throw new IllegalStateException("the editable text field refused the text after it was focused");
      return typed(value);
    }
    field.performAction(AccessibilityNodeInfo.ACTION_FOCUS);
    return null;
  }

  /**
   * Types again after the focus request has had {@link #FOCUS_SETTLE_MS} to take effect.
   *
   * Not onMain(): its body runs *and is awaited* on the main thread, so a delay posted from there
   * would never elapse. Post the retry, wait on the calling thread.
   */
  private JSONObject typeAfterFocus(final String value) throws Exception {
    final JSONObject[] result = new JSONObject[1];
    final Exception[] failure = new Exception[1];
    final CountDownLatch done = new CountDownLatch(1);
    main.postDelayed(new Runnable() {
      @Override
      public void run() {
        try {
          result[0] = typeNow(value, false);
        } catch (Exception e) {
          failure[0] = e;
        } finally {
          done.countDown();
        }
      }
    }, FOCUS_SETTLE_MS);
    if (!done.await(OP_TIMEOUT_MS, TimeUnit.MILLISECONDS)) throw new IllegalStateException("the typing retry timed out");
    if (failure[0] != null) throw failure[0];
    return result[0];
  }

  /** Editable nodes in the active window, in tree order. */
  private static List<AccessibilityNodeInfo> editableNodes(AccessibilityNodeInfo root) {
    List<AccessibilityNodeInfo> found = new ArrayList<>();
    ArrayDeque<AccessibilityNodeInfo> queue = new ArrayDeque<>();
    queue.add(root);
    for (int visited = 0; visited < FIND_SCAN_CAP && !queue.isEmpty(); visited++) {
      AccessibilityNodeInfo node = queue.poll();
      if (node.isEditable()) found.add(node);
      for (int i = 0; i < node.getChildCount(); i++) {
        AccessibilityNodeInfo child = node.getChild(i);
        if (child != null) queue.add(child);
      }
    }
    return found;
  }

  /** "终端输入 / Search": one short label per candidate, for the several-edit-boxes error. */
  private static String describe(List<AccessibilityNodeInfo> nodes) {
    StringBuilder out = new StringBuilder();
    for (AccessibilityNodeInfo node : nodes) {
      if (out.length() > 0) out.append(" / ");
      out.append(label(node));
    }
    return out.toString();
  }

  /**
   * `终端输入` / `Search | dsh`: a node's hint and its text, each clipped to
   * {@link #CANDIDATE_LABEL_CHARS} characters, so several look-alike fields stay distinguishable.
   */
  private static String label(AccessibilityNodeInfo node) {
    String hint = clipped(node.getHintText());
    String text = clipped(node.getText());
    if (!hint.isEmpty() && !text.isEmpty() && !hint.equals(text)) return hint + " | " + text;
    if (!hint.isEmpty()) return hint;
    return text.isEmpty() ? "<no label>" : text;
  }

  /** Trimmed, single-spaced, at most {@link #CANDIDATE_LABEL_CHARS} characters. */
  private static String clipped(CharSequence value) {
    if (value == null) return "";
    String text = value.toString().trim().replaceAll("\\s+", " ");
    return text.length() > CANDIDATE_LABEL_CHARS ? text.substring(0, CANDIDATE_LABEL_CHARS) + "…" : text;
  }

  /** The one ACTION_SET_TEXT request both the focused field and the fallback field use. */
  private static boolean setText(AccessibilityNodeInfo node, String value) {
    Bundle arguments = new Bundle();
    arguments.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value);
    return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments);
  }

  /** The shape the bridge hands the agent: `{ok, length}`. */
  private static JSONObject typed(String value) throws Exception {
    JSONObject out = new JSONObject();
    out.put("ok", true);
    out.put("length", value.length());
    return out;
  }

  /** Current screen as a base64 JPEG, shrunk until it fits `maxBytes`. */
  public String screenshot(final int maxBytes) throws Exception {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) throw new IllegalStateException("screenshot needs Android 11+");
    final int budget = maxBytes > 0 ? maxBytes : DEFAULT_MAX_IMAGE_BYTES;
    final Object[] shot = new Object[1];        // the wrapped Bitmap on success, an Exception on failure
    final HardwareBuffer[] buffer = new HardwareBuffer[1];
    final CountDownLatch done = new CountDownLatch(1);
    // Same trap as gesture(): takeScreenshot() belongs on the main thread and getMainExecutor()
    // delivers its callback there too, so awaiting it on the main thread guaranteed a timeout.
    // Wait on the calling thread and keep the buffer open until the JPEG is encoded.
    main.post(new Runnable() {
      @Override
      public void run() {
        try {
          takeScreenshot(Display.DEFAULT_DISPLAY, getMainExecutor(), new TakeScreenshotCallback() {
            @Override
            public void onSuccess(ScreenshotResult result) {
              try {
                buffer[0] = result.getHardwareBuffer();
                Bitmap bitmap = Bitmap.wrapHardwareBuffer(buffer[0], result.getColorSpace());
                if (bitmap == null) throw new IllegalStateException("cannot read the screenshot bitmap");
                shot[0] = bitmap;
              } catch (Exception e) {
                shot[0] = e;
              } finally {
                done.countDown();
              }
            }

            @Override
            public void onFailure(int errorCode) {
              shot[0] = new IllegalStateException("screenshot failed with code " + errorCode);
              done.countDown();
            }
          });
        } catch (Exception e) {
          shot[0] = e;
          done.countDown();
        }
      }
    });
    if (!done.await(OP_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
      if (buffer[0] != null) buffer[0].close();
      throw new IllegalStateException("screenshot timed out");
    }
    try {
      if (shot[0] instanceof Exception) throw (Exception) shot[0];
      Bitmap wrapped = (Bitmap) shot[0];
      // compress() reads through the hardware buffer; a software copy keeps the scaling path simple
      // and gets the whole encode off the main thread (it used to run inside the callback).
      Bitmap source = wrapped.getConfig() == Bitmap.Config.HARDWARE
        ? wrapped.copy(Bitmap.Config.ARGB_8888, false)
        : wrapped;
      return encodeJpeg(source, budget);
    } finally {
      if (buffer[0] != null) buffer[0].close();
    }
  }

  /** Scales and re-encodes until the JPEG fits the byte budget. */
  private static String encodeJpeg(Bitmap source, int budget) {
    int[] scales = { 100, 75, 55, 40, 28 };
    int[] qualities = { 80, 65, 50, 35 };
    byte[] best = null;
    int width = source.getWidth();
    int height = source.getHeight();
    for (int scale : scales) {
      Bitmap scaled = scale == 100
        ? source
        : Bitmap.createScaledBitmap(source, Math.max(1, source.getWidth() * scale / 100), Math.max(1, source.getHeight() * scale / 100), true);
      width = scaled.getWidth();
      height = scaled.getHeight();
      for (int quality : qualities) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        scaled.compress(Bitmap.CompressFormat.JPEG, quality, out);
        byte[] bytes = out.toByteArray();
        if (best == null || bytes.length < best.length) best = bytes;
        if (bytes.length <= budget) {
          best = bytes;
          scaled = null;
          break;
        }
      }
      if (scaled != null && scaled != source) scaled.recycle();
      if (best != null && best.length <= budget) break;
    }
    JSONObject meta = new JSONObject();
    try {
      meta.put("image", Base64.encodeToString(best, Base64.NO_WRAP));
      meta.put("mime", "image/jpeg");
      meta.put("width", width);
      meta.put("height", height);
      meta.put("bytes", best.length);
    } catch (Exception ignored) {
      // The fields above are all plain values, so this cannot fail in practice.
    }
    return meta.toString();
  }

  public boolean tap(final int x, final int y) throws Exception {
    Path path = new Path();
    path.moveTo(x, y);
    return gesture(path, 0, 60);
  }

  public boolean swipe(final int x1, final int y1, final int x2, final int y2, final int durationMs) throws Exception {
    Path path = new Path();
    path.moveTo(x1, y1);
    path.lineTo(x2, y2);
    return gesture(path, 0, Math.max(50, durationMs));
  }

  private boolean gesture(final Path path, final long startMs, final long durationMs) throws Exception {
    GestureDescription.Builder builder = new GestureDescription.Builder();
    builder.addStroke(new GestureDescription.StrokeDescription(path, startMs, durationMs));
    final GestureDescription description = builder.build();
    final CountDownLatch done = new CountDownLatch(1);
    final boolean[] ok = new boolean[1];
    final Exception[] failure = new Exception[1];
    // dispatchGesture() must be called from the main thread, but its result callback is posted back
    // to the main thread as well. Awaiting that callback *inside* onMain() — which is what this did
    // — froze the UI for the whole timeout, ANR'd the app and took the bridge socket down with it:
    // every tap or swipe from the agent ended with the phone going offline. Dispatch on the main
    // thread, wait on the calling one.
    main.post(new Runnable() {
      @Override
      public void run() {
        try {
          boolean dispatched = dispatchGesture(description, new GestureResultCallback() {
            @Override
            public void onCompleted(GestureDescription d) {
              ok[0] = true;
              done.countDown();
            }

            @Override
            public void onCancelled(GestureDescription d) {
              ok[0] = false;
              done.countDown();
            }
          }, main);
          if (!dispatched) throw new IllegalStateException("the gesture was not accepted");
        } catch (Exception e) {
          failure[0] = e;
          done.countDown();
        }
      }
    });
    if (!done.await(OP_TIMEOUT_MS, TimeUnit.MILLISECONDS)) throw new IllegalStateException("the gesture timed out");
    if (failure[0] != null) throw failure[0];
    return ok[0];
  }

  /** back / home / recents / notifications / quick_settings. */
  public boolean global(final String action) throws Exception {
    int code;
    switch (action == null ? "" : action) {
      case "back":
        code = GLOBAL_ACTION_BACK;
        break;
      case "home":
        code = GLOBAL_ACTION_HOME;
        break;
      case "recents":
        code = GLOBAL_ACTION_RECENTS;
        break;
      case "notifications":
        code = GLOBAL_ACTION_NOTIFICATIONS;
        break;
      case "quick_settings":
        code = GLOBAL_ACTION_QUICK_SETTINGS;
        break;
      case "lock":
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) throw new IllegalStateException("lock needs Android 9+");
        code = GLOBAL_ACTION_LOCK_SCREEN;
        break;
      default:
        throw new IllegalStateException("unknown global action: " + action);
    }
    final int target = code;
    return onMain(() -> performGlobalAction(target));
  }
}
