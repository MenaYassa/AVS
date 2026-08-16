package com.example.ui.home

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.data.model.Session
import com.example.data.repository.KnowledgeRepository
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

enum class HomeFilter(val label: String) {
    ALL("All"),
    FAVORITES("Favorites"),
    PINNED("Pinned"),
    ARCHIVED("Archived")
}

data class HomeUiState(
    val sessions: List<Session> = emptyList(),
    val filter: HomeFilter = HomeFilter.ALL,
    val selectedTag: String? = null,
    val searchQuery: String = "",
    val isLoading: Boolean = false
)

class HomeViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = KnowledgeRepository.getInstance(application)

    private val _filter = MutableStateFlow(HomeFilter.ALL)
    private val _selectedTag = MutableStateFlow<String?>(null)
    private val _searchQuery = MutableStateFlow("")

    val uiState: StateFlow<HomeUiState> = combine(
        repository.allSessions,
        _filter,
        _selectedTag,
        _searchQuery
    ) { sessions, filter, tag, query ->
        val filtered = sessions.filter { session ->
            val matchesFilter = when (filter) {
                HomeFilter.ALL -> !session.archived
                HomeFilter.FAVORITES -> session.favorite && !session.archived
                HomeFilter.PINNED -> session.pinned && !session.archived
                HomeFilter.ARCHIVED -> session.archived
            }
            val matchesTag = tag == null || session.tags.contains(tag)
            val matchesQuery = query.isBlank() ||
                    (session.title?.contains(query, ignoreCase = true) == true) ||
                    (session.summary?.contains(query, ignoreCase = true) == true) ||
                    (session.cleanedTranscript?.contains(query, ignoreCase = true) == true)

            matchesFilter && matchesTag && matchesQuery
        }
        HomeUiState(
            sessions = filtered,
            filter = filter,
            selectedTag = tag,
            searchQuery = query,
            isLoading = false
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5000),
        initialValue = HomeUiState(isLoading = true)
    )

    fun setFilter(filter: HomeFilter) {
        _filter.value = filter
        _selectedTag.value = null
    }

    fun selectTag(tag: String?) {
        _selectedTag.value = if (_selectedTag.value == tag) null else tag
    }

    fun setSearchQuery(query: String) {
        _searchQuery.value = query
    }

    fun toggleFavorite(session: Session) {
        viewModelScope.launch {
            repository.toggleFavorite(session.id, session.favorite)
        }
    }

    fun togglePin(session: Session) {
        viewModelScope.launch {
            repository.togglePinned(session.id, session.pinned)
        }
    }

    fun deleteSession(session: Session) {
        viewModelScope.launch {
            repository.deleteSession(session.id)
        }
    }

    fun toggleArchive(session: Session) {
        viewModelScope.launch {
            repository.toggleArchived(session.id, session.archived)
        }
    }

    fun archiveSession(session: Session) {
        viewModelScope.launch {
            repository.setArchived(session.id, true)
        }
    }

    fun unarchiveSession(session: Session) {
        viewModelScope.launch {
            repository.setArchived(session.id, false)
        }
    }

    fun restoreSession(session: Session) {
        viewModelScope.launch {
            repository.restoreSession(session)
        }
    }

    fun duplicateSession(session: Session) {
        viewModelScope.launch {
            repository.duplicateSession(session)
        }
    }

    fun renameSession(session: Session, newTitle: String) {
        if (newTitle.isBlank()) return
        viewModelScope.launch {
            repository.renameSession(session.id, newTitle.trim())
        }
    }
}
