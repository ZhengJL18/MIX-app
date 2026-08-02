package com.mix.mix_app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

/**
 * 持有 Hermes 进程的前台服务。
 *
 * 前台服务把 App 进程抬到 foreground 级（oom_adj 低），
 * 内存紧张时系统不会优先杀掉 App 及其子进程（Hermes gateway）。
 * 用户切后台 / App 退到后台，Hermes 仍存活，任务不中断。
 *
 * Android 15+ 用 specialUse 类型绕开 6 小时超时限制。
 */
public class HermesForegroundService extends Service {
    private static final String CHANNEL_ID = "hermes_agent";
    private static final String CHANNEL_NAME = "本地 AI 引擎";

    @Override
    public void onCreate() {
        super.onCreate();
        createChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // 常驻通知：告知用户 Hermes 在后台运行
        Notification notification = buildNotification();
        // Android 14+ 需要指定 foregroundServiceType
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
            } else {
                startForeground(1, notification);
            }
        } else {
            startForeground(1, notification);
        }
        // START_STICKY：服务被杀后系统自动重启它（除非明确 stop）
        return START_STICKY;
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW);
            channel.setDescription("保持本地 AI 引擎（Hermes）在后台运行");
            NotificationManager nm = getSystemService(NotificationManager.class);
            nm.createNotificationChannel(channel);
        }
    }

    private Notification buildNotification() {
        Intent notificationIntent = new Intent(this, MainActivity.class);
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = new Notification.Builder(this, CHANNEL_ID);
        } else {
            builder = new Notification.Builder(this);
        }
        return builder
            .setContentTitle("MIX 本地 AI")
            .setContentText("Hermes 引擎运行中，AI 任务持续进行")
            .setSmallIcon(android.R.drawable.ic_popup_sync)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
