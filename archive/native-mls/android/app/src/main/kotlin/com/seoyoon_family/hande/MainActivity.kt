package com.seoyoon_family.hande

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.lifecycle.lifecycleScope
import com.seoyoon_family.hande.ui.HandeRoot

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as HandeApp
        app.hub.start(lifecycleScope)
        setContent {
            MaterialTheme { HandeRoot(app.hub) }
        }
    }
}
