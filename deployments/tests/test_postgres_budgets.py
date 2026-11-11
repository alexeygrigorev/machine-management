import importlib.util
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location('postgres_budgets', Path(__file__).parents[1] / 'postgres-budgets.py')
budgets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budgets)


def runtime():
    return {'Name': '/' + budgets.DATABASES[0], 'Config': {'Image': 'postgres:16'},
            'State': {'Running': True, 'Health': {'Status': 'healthy'}}, 'HostConfig': {'Memory': 0}}


def database():
    return {'uuid': budgets.DATABASES[0], 'database_type': 'standalone-postgresql'}


@pytest.mark.parametrize('value,expected', [('1.25GiB', 1.25 * 1024**3), ('512MiB', 512 * 1024**2), ('42B', 42)])
def test_docker_memory_units(value, expected):
    assert budgets.memory_bytes(value) == expected


@pytest.mark.parametrize('change', ['identity', 'image', 'health', 'existing-limit', 'usage'])
def test_refuses_unsafe_database_changes(change):
    db, container, usage = database(), runtime(), 1024**3
    if change == 'identity':
        db['uuid'] = 'unrelated-database'
    elif change == 'image':
        container['Config']['Image'] = 'postgres:17'
    elif change == 'health':
        container['State']['Health']['Status'] = 'unhealthy'
    elif change == 'existing-limit':
        container['HostConfig']['Memory'] = 16 * 1024**3
    else:
        usage = 5 * 1024**3
    with pytest.raises(ValueError):
        budgets.validate(db, container, usage)


def test_accepts_audited_healthy_postgres_with_headroom():
    budgets.validate(database(), runtime(), 1.4 * 1024**3)
