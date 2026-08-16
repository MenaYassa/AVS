"""Tests for embedding provider and embedding stage."""

from unittest.mock import MagicMock, patch

import pytest
from app.inputs.base import InputDoc
from app.providers.embedding import (
    SentenceTransformerEmbedding,
    get_embedding_provider,
)
from app.stages.context import StageContext, TokenBudget
from app.stages.embedding import EmbeddingStage
from numpy import array


@pytest.fixture
def mock_transformer():
    with patch("sentence_transformers.SentenceTransformer") as mock:
        model = MagicMock()
        model.encode.return_value = array([[0.1, 0.2, 0.3], [0.1, 0.2, 0.3]])
        mock.return_value = model
        yield mock


def test_sentence_transformer_embedding_provider(mock_transformer):
    provider = SentenceTransformerEmbedding()
    assert provider.dimensions == 384
    assert mock_transformer.call_count == 0
    model = provider._load_model()
    assert model is not None
    assert mock_transformer.call_count == 1


def test_sentence_transformer_embed_batch(mock_transformer):
    provider = SentenceTransformerEmbedding()
    result = provider.embed_batch(["hello world", "test"])
    assert len(result) == 2
    assert result[0] == [0.1, 0.2, 0.3]


def test_sentence_transformer_embed(mock_transformer):
    provider = SentenceTransformerEmbedding()
    result = provider.embed("hello world")
    assert result == [0.1, 0.2, 0.3]


def test_get_embedding_provider():
    provider = get_embedding_provider()
    assert isinstance(provider, SentenceTransformerEmbedding)
    assert provider.dimensions == 384


class TestEmbeddingStage:
    @pytest.fixture
    def stage(self):
        return EmbeddingStage()

    @pytest.fixture
    def mock_provider(self):
        mock = MagicMock()
        mock.dimensions = 384
        mock.embed.return_value = [0.5, 0.6, 0.7]
        return mock

    @pytest.fixture
    def ctx_with_validation(self):
        input_doc = InputDoc(
            kind="voice",
            text="",
            meta={},
            blob_ref="",
        )
        ctx = StageContext(
            input_doc=input_doc,
            prompt_versions={},
            budget=TokenBudget(max_input_tokens=32000, max_output_tokens=8192),
        )
        ctx.intermediates["validation"] = {
            "title": "Test Session",
            "summary": "A summary",
            "topics": [
                {
                    "title": "Topic 1",
                    "items": [
                        {"content": "Item 1 content"},
                        {"content": "Item 2 content"},
                    ],
                }
            ],
        }
        return ctx

    def test_build_with_validation(self, stage, mock_provider, ctx_with_validation):
        stage._provider = mock_provider
        result = stage.build(ctx_with_validation)
        assert "embedding" in result
        assert result["embedding"] == [0.5, 0.6, 0.7]
        assert result["dimension"] == 384
        assert result["text_length"] > 0

    def test_build_no_validation(self, stage, mock_provider):
        input_doc = InputDoc(
            kind="voice",
            text="",
            meta={},
            blob_ref="",
        )
        ctx = StageContext(
            input_doc=input_doc,
            prompt_versions={},
            budget=TokenBudget(max_input_tokens=32000, max_output_tokens=8192),
        )
        stage._provider = mock_provider
        result = stage.build(ctx)
        assert result == {"embedding": [], "dimension": 0}

    def test_build_calls_embed(self, stage, mock_provider, ctx_with_validation):
        stage._provider = mock_provider
        stage.build(ctx_with_validation)
        mock_provider.embed.assert_called_once()
        call_text = mock_provider.embed.call_args[0][0]
        assert "Test Session" in call_text
        assert "Topic 1" in call_text
        assert "Item 1 content" in call_text
