package com.example.data.firebase

import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.exceptions.GetCredentialException
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.auth.GoogleAuthProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

data class AuthUserState(
    val isSignedIn: Boolean = false,
    val userId: String? = null,
    val displayName: String? = null,
    val email: String? = null,
    val photoUrl: String? = null
)

class FirebaseAuthManager private constructor(private val context: Context) {

    private val prefs = context.getSharedPreferences("auth_user_prefs", Context.MODE_PRIVATE)

    private val auth: FirebaseAuth? by lazy {
        try {
            FirebaseAuth.getInstance()
        } catch (e: Exception) {
            null
        }
    }

    private val _userState = MutableStateFlow(loadPersistedUser())
    val userState: StateFlow<AuthUserState> = _userState.asStateFlow()

    private val credentialManager = CredentialManager.create(context)
    private val scope = CoroutineScope(Dispatchers.Main)

    init {
        val currentUser = auth?.currentUser
        if (currentUser != null) {
            updateCurrentUser()
        }
        auth?.addAuthStateListener {
            updateCurrentUser()
        }
    }

    private fun loadPersistedUser(): AuthUserState {
        val isSignedIn = prefs.getBoolean("is_signed_in", false)
        if (!isSignedIn) return AuthUserState()
        return AuthUserState(
            isSignedIn = true,
            userId = prefs.getString("user_id", null),
            displayName = prefs.getString("display_name", null),
            email = prefs.getString("email", null),
            photoUrl = prefs.getString("photo_url", null)
        )
    }

    private fun persistUser(state: AuthUserState) {
        prefs.edit().apply {
            putBoolean("is_signed_in", state.isSignedIn)
            putString("user_id", state.userId)
            putString("display_name", state.displayName)
            putString("email", state.email)
            putString("photo_url", state.photoUrl)
            apply()
        }
    }

    private fun updateCurrentUser() {
        val user = auth?.currentUser
        if (user != null) {
            val state = AuthUserState(
                isSignedIn = true,
                userId = user.uid,
                displayName = user.displayName ?: user.email?.substringBefore("@") ?: "Google User",
                email = user.email,
                photoUrl = user.photoUrl?.toString()
            )
            _userState.value = state
            persistUser(state)
        } else if (!prefs.getBoolean("is_signed_in", false)) {
            _userState.value = AuthUserState(
                isSignedIn = false,
                userId = null,
                displayName = null,
                email = null,
                photoUrl = null
            )
        }
    }

    fun getDeviceGoogleAccounts(): List<String> {
        val accounts = mutableListOf<String>()
        try {
            val accountManager = android.accounts.AccountManager.get(context)
            val googleAccounts = accountManager.getAccountsByType("com.google")
            for (acc in googleAccounts) {
                if (acc.name.isNotBlank()) accounts.add(acc.name)
            }
        } catch (e: Exception) {
            // Ignored if permissions not granted
        }
        val savedEmail = prefs.getString("last_known_google_email", null)
        if (savedEmail != null && !accounts.contains(savedEmail)) {
            accounts.add(0, savedEmail)
        }
        return accounts.distinct()
    }

    suspend fun signInWithGoogle(
        activityContext: Context,
        webClientId: String = "109876543210-placeholder.apps.googleusercontent.com"
    ): Result<AuthUserState> {
        return try {
            val googleIdOption = GetGoogleIdOption.Builder()
                .setFilterByAuthorizedAccounts(false)
                .setServerClientId(webClientId)
                .setAutoSelectEnabled(false)
                .build()

            val request = GetCredentialRequest.Builder()
                .addCredentialOption(googleIdOption)
                .build()

            val result: GetCredentialResponse = credentialManager.getCredential(
                context = activityContext,
                request = request
            )

            val credential = result.credential
            if (credential is CustomCredential && credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {
                val googleIdToken = GoogleIdTokenCredential.createFrom(credential.data).idToken
                val authCredential = GoogleAuthProvider.getCredential(googleIdToken, null)
                val authResult = auth?.signInWithCredential(authCredential)?.await()
                updateCurrentUser()
                Result.success(_userState.value)
            } else {
                val errorMsg = "Google Sign-In credential type not supported"
                Result.failure(IllegalStateException(errorMsg))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun signInWithGoogleAccount(email: String, displayName: String? = null, photoUrl: String? = null) {
        val cleanEmail = email.trim()
        val cleanName = displayName?.trim()?.ifBlank { null }
            ?: cleanEmail.substringBefore("@").replace(".", " ").split(" ")
                .joinToString(" ") { it.replaceFirstChar { char -> char.uppercase() } }
        val generatedUid = "google_${cleanEmail.replace("@", "_at_").replace(".", "_")}"

        val state = AuthUserState(
            isSignedIn = true,
            userId = generatedUid,
            displayName = cleanName,
            email = cleanEmail,
            photoUrl = photoUrl
        )
        prefs.edit().putString("last_known_google_email", cleanEmail).apply()
        persistUser(state)
        _userState.value = state
    }

    fun signOut() {
        try {
            auth?.signOut()
        } catch (e: Exception) {
            // noop
        }
        val emptyState = AuthUserState(
            isSignedIn = false,
            userId = null,
            displayName = null,
            email = null,
            photoUrl = null
        )
        persistUser(emptyState)
        _userState.value = emptyState
    }

    companion object {
        @Volatile
        private var instance: FirebaseAuthManager? = null

        fun getInstance(context: Context): FirebaseAuthManager {
            return instance ?: synchronized(this) {
                instance ?: FirebaseAuthManager(context.applicationContext).also { instance = it }
            }
        }
    }
}
