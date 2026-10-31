package com.frec86.syncnotes

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val title = intent.getStringExtra("title") ?: "SyncNotes"
        val text = intent.getStringExtra("text") ?: ""
        val nm = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel("reminders", "提醒", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val notification = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(context, "reminders")
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }.setContentTitle(title).setContentText(text).setSmallIcon(android.R.drawable.ic_dialog_info).build()
        nm.notify(title.hashCode(), notification)
    }
}
