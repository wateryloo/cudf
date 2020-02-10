import numpy as np
import pandas as pd
import pytest

import cudf
from cudf.core.column import as_column
from cudf.core.column_accessor import ColumnAccessor
from cudf.tests.utils import assert_eq

simple_test_data = [
    {},
    {"a": []},
    {"a": [1]},
    {"a": ["a"]},
    {"a": [1, 2, 3], "b": ["a", "b", "c"]},
]

mi_test_data = [
    {("a", "b"): [1, 2, 4], ("a", "c"): [2, 3, 4]},
    {("a", "b"): [1, 2, 3], ("a", ""): [2, 3, 4]},
    {("a", "b"): [1, 2, 4], ("c", "d"): [2, 3, 4]},
    {("a", "b"): [1, 2, 3], ("a", "c"): [2, 3, 4], ("b", ""): [4, 5, 6]},
]


def check_ca_equal(lhs, rhs):
    assert lhs.level_names == rhs.level_names
    assert lhs.multiindex == rhs.multiindex
    for l_key, r_key in zip(lhs, rhs):
        assert l_key == r_key
        assert_eq(lhs[l_key], rhs[r_key])


@pytest.fixture(params=simple_test_data)
def simple_data(request):
    return request.param


@pytest.fixture(params=mi_test_data)
def mi_data(request):
    return request.param


@pytest.fixture(params=simple_test_data + mi_test_data)
def all_data(request):
    return request.param


def test_to_pandas_simple(simple_data):
    """
    Test that a ColumnAccessor converts to a correct pd.Index
    """
    ca = ColumnAccessor(simple_data)
    assert_eq(ca.to_pandas_index(), pd.DataFrame(simple_data).columns)


def test_to_pandas_multiindex(mi_data):
    ca = ColumnAccessor(mi_data, multiindex=True)
    assert_eq(ca.to_pandas_index(), pd.DataFrame(mi_data).columns)


def test_iter(simple_data):
    """
    Test that iterating over the CA
    yields column names.
    """
    ca = ColumnAccessor(simple_data)
    for expect_key, got_key in zip(simple_data, ca):
        assert expect_key == got_key


def test_all_columns(simple_data):
    """
    Test that all values of the CA are
    columns.
    """
    ca = ColumnAccessor(simple_data)
    for col in ca.values():
        assert isinstance(col, cudf.core.column.ColumnBase)


def test_column_size_mismatch():
    """
    Test that constructing a CA from columns of
    differing sizes throws an error.
    """
    with pytest.raises(ValueError):
        _ = ColumnAccessor({"a": [1], "b": [1, 2]})


def test_get_by_label_simple():
    """
    Test getting a column by label
    """
    ca = ColumnAccessor({"a": [1, 2, 3], "b": [2, 3, 4]})
    check_ca_equal(ca.get_by_label("a"), ColumnAccessor({"a": [1, 2, 3]}))
    check_ca_equal(ca.get_by_label("b"), ColumnAccessor({"b": [2, 3, 4]}))


def test_get_by_label_multiindex():
    """
    Test getting column(s) by label with MultiIndex
    """
    ca = ColumnAccessor(
        {
            ("a", "b", "c"): [1, 2, 3],
            ("a", "b", "e"): [2, 3, 4],
            ("b", "x", ""): [4, 5, 6],
            ("a", "d", "e"): [3, 4, 5],
        },
        multiindex=True,
    )

    expect = ColumnAccessor(
        {("b", "c"): [1, 2, 3], ("b", "e"): [2, 3, 4], ("d", "e"): [3, 4, 5]},
        multiindex=True,
    )
    got = ca.get_by_label("a")
    check_ca_equal(expect, got)

    expect = ColumnAccessor({"c": [1, 2, 3], "e": [2, 3, 4]}, multiindex=False)
    got = ca.get_by_label(("a", "b"))
    check_ca_equal(expect, got)
