package com.mix.mix_app;

import android.content.Intent;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "com.mix.mix_app/hermes_service";

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "startHermesService":
                        startForegroundServiceCompat();
                        result.success(true);
                        break;
                    case "stopHermesService":
                        stopService(new Intent(this, HermesForegroundService.class));
                        result.success(true);
                        break;
                    default:
                        result.notImplemented();
                }
            });
    }

    private void startForegroundServiceCompat() {
        Intent intent = new Intent(this, HermesForegroundService.class);
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            startForegroundService(intent);
        } else {
            startService(intent);
        }
    }
}
