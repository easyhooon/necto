// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.sample

import android.app.Application
import im.toss.necto.android.NectoAndroid

/** Verifies the SDK's connection and the plugin bridge on a device or an emulator. */
class SampleApp : Application() {
    override fun onCreate() {
        super.onCreate()
        if (BuildConfig.DEBUG) {
            // A capability the Mac can call into: the round trip the bridge exists for.
            NectoAndroid.start(this, listOf(ExampleContractPlugin(this)))
        }
    }
}
