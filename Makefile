.PHONY: test test-unit test-integration test-restart test-e2e compose-validate

test: test-unit test-integration

test-unit:
	python3 -m unittest discover -s tests/unit -v

test-integration:
	python3 -m unittest discover -s tests/integration -v

test-restart:
	python3 -m unittest discover -s tests/restart -v

test-e2e:
	python3 tests/e2e/test_tableflow_federation.py

compose-validate:
	docker compose config -q
