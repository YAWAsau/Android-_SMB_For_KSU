package com.yawasau.smbnotify;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.os.DeadObjectException;
import android.os.IBinder;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.reflect.InvocationTargetException;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/** SMB adaptation of YAWAsau Mount NotificationUtil's one-shot root/system-context
 * sender, BigText notification and Canvas small-icon approach. See README.md.
 * No background service, retries, polling, progress/state-file machinery. */
public final class SmbNotifyUtil {
    static android.graphics.Bitmap buildSmbIconBitmap(int sizePx) {
        android.graphics.Bitmap bmp = android.graphics.Bitmap.createBitmap(sizePx, sizePx, android.graphics.Bitmap.Config.ARGB_8888);
        android.graphics.Canvas c = new android.graphics.Canvas(bmp);
        c.scale(sizePx / 24f, sizePx / 24f);
        android.graphics.Paint fill = new android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG);
        fill.setColor(android.graphics.Color.WHITE);
        android.graphics.Path folder = new android.graphics.Path();
        folder.moveTo(3, 3); folder.lineTo(9, 3); folder.lineTo(11, 5);
        folder.lineTo(21, 5); folder.lineTo(21, 13); folder.lineTo(3, 13); folder.close();
        c.drawPath(folder, fill);
        // One shared folder feeding two network endpoints; 2px stems at 24px.
        c.drawRect(11, 13, 13, 18, fill);
        c.drawRect(5, 16, 19, 18, fill);
        c.drawRect(5, 17, 7, 20, fill); c.drawRect(17, 17, 19, 20, fill);
        c.drawRoundRect(3, 19, 9, 23, 1, 1, fill);
        c.drawRoundRect(15, 19, 21, 23, 1, 1, fill);
        return bmp;
    }
    private static android.graphics.drawable.Icon buildSmbIcon() {
        return android.graphics.drawable.Icon.createWithBitmap(buildSmbIconBitmap(96));
    }
    static final String CHANNEL = "SMB_SERVER_EVENTS_V2";
    interface Backend {
        boolean available() throws Exception;
        void send() throws Exception;
    }
    static String deliver(Backend backend) throws Exception {
        if (!backend.available()) return "SMB_NOTIFY_SKIPPED reason=service_unavailable";
        try {
            backend.send();
            return "SMB_NOTIFY_SENT";
        } catch (Exception e) {
            Throwable cause = e;
            while (cause.getCause() != null && cause.getCause() != cause) cause = cause.getCause();
            if (cause instanceof DeadObjectException ||
                (cause instanceof NullPointerException && !backend.available())) {
                return "SMB_NOTIFY_SKIPPED reason=service_disappeared";
            }
            throw e;
        }
    }
    static boolean shuttingDown() throws Exception {
        Class<?> props = Class.forName("android.os.SystemProperties");
        String value = (String) props.getMethod("get", String.class, String.class)
            .invoke(null, "sys.shutdown.requested", "");
        return !value.isEmpty();
    }
    static IBinder notificationService() throws Exception {
        return (IBinder) Class.forName("android.os.ServiceManager")
            .getMethod("checkService", String.class).invoke(null, "notification");
    }
    static Map<String,String> readInput() throws Exception {
        Map<String,String> fields = new HashMap<>();
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        int total = 0;
        for (String line; (line = in.readLine()) != null;) {
            total += line.length();
            if (total > 32768) throw new IllegalArgumentException("notification input too large");
            if (line.equals("END")) break;
            int split = line.indexOf('|');
            if (split > 0) fields.put(line.substring(0, split), line.substring(split + 1));
        }
        return fields;
    }
    public static void main(String[] args) {
        try {
            if (args.length != 2 || !args[0].equals("notify") || !args[1].equals("--stdin"))
                throw new IllegalArgumentException("expected notify --stdin");
            final Map<String,String> fields = readInput();
            String result = deliver(new Backend() {
                public boolean available() throws Exception {
                    if (shuttingDown()) return false;
                    IBinder service = notificationService();
                    return service != null && service.isBinderAlive();
                }
                public void send() throws Exception {
                    if (android.os.Looper.myLooper() == null) android.os.Looper.prepareMainLooper();
                    Class<?> threadClass = Class.forName("android.app.ActivityThread");
                    Object thread = threadClass.getMethod("systemMain").invoke(null);
                    Context context = (Context) threadClass.getMethod("getSystemContext").invoke(thread);
                    NotificationManager manager = context.getSystemService(NotificationManager.class);
                    if (manager == null) throw new NullPointerException("notification manager unavailable");
                    NotificationChannel channel = new NotificationChannel(CHANNEL, "SMB 伺服器", NotificationManager.IMPORTANCE_DEFAULT);
                    channel.setDescription("SMB 啟停與區域網路狀態");
                    // Retain Mount's system-context notification path, with the backup
                    // script's package-UID channel registration correction:
                    // root calls as UID 0, but the system context belongs to android/1000.
                    // Register the channel against the package UID, not root's Binder UID.
                    IBinder binder = notificationService();
                    if (binder == null) throw new DeadObjectException();
                    Class<?> api = Class.forName("android.app.INotificationManager");
                    Object service = Class.forName("android.app.INotificationManager$Stub")
                        .getMethod("asInterface", IBinder.class).invoke(null, binder);
                    Class<?> sliceClass = Class.forName("android.content.pm.ParceledListSlice");
                    Object channels = sliceClass.getConstructor(java.util.List.class)
                        .newInstance(java.util.Collections.singletonList(channel));
                    api.getMethod("createNotificationChannelsForPackage", String.class, int.class, sliceClass)
                        .invoke(service, context.getPackageName(),
                            context.getPackageManager().getPackageUid(context.getPackageName(), 0), channels);
                    Notification notification = new Notification.Builder(context, CHANNEL)
                        .setSmallIcon(buildSmbIcon())
                        .setColor(0xFF2D8CFF)
                        .setContentTitle(fields.getOrDefault("TITLE", "SMB 伺服器"))
                        .setContentText(fields.getOrDefault("TEXT", ""))
                        .setStyle(new Notification.BigTextStyle().bigText(fields.getOrDefault("BIGTEXT", fields.getOrDefault("TEXT", ""))))
                        .setOnlyAlertOnce(true).setAutoCancel(true).setShowWhen(true).build();
                    manager.notify("smbdwebui", 20261011, notification);
                }
            });
            System.out.println(result);
        } catch (Exception e) {
            Throwable cause = e;
            while (cause instanceof InvocationTargetException && cause.getCause() != null) cause = cause.getCause();
            System.out.println("SMB_NOTIFY_FAILED reason=" + cause.getClass().getSimpleName());
            cause.printStackTrace(System.err);
            System.exit(1);
        }
    }
}
