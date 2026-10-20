// 앱 프로세스 1개 = 단일 작성자(HOST-CONTRACT §1). 허브는 프로세스 수명.
package com.seoyoon_family.hande

import android.app.Application
import com.seoyoon_family.hande.core.DeviceHub
import com.seoyoon_family.hande.core.KeystoreSealer
import com.seoyoon_family.hande.core.Settings

class HandeApp : Application() {
    val sealer by lazy { KeystoreSealer() }
    val settings by lazy { Settings(this, sealer) }
    val hub by lazy { DeviceHub(this, settings, sealer) }
}
