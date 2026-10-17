import copy
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('upstream_compatibility', Path(__file__).parents[1] / 'upstream_compatibility.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def contract():
    return {'paths': {'/assets': {'post': {
        'operationId': 'createAsset', 'security': [{'api_key': []}],
        'parameters': [{'in': 'query', 'name': 'owner', 'required': False, 'schema': {'type': 'string'}}],
        'requestBody': {'required': True, 'content': {'application/json': {'schema': {'$ref': '#/components/schemas/Asset'}}}},
        'responses': {'200': {'content': {'application/json': {'schema': {'$ref': '#/components/schemas/Asset'}}}}},
    }}}, 'components': {'securitySchemes': {'api_key': {'type': 'apiKey', 'in': 'header', 'name': 'x-api-key'}},
                      'schemas': {'Asset': {'type': 'object', 'required': ['id'],
                                           'properties': {'id': {'type': 'string'}, 'type': {'type': 'string', 'enum': ['IMAGE', 'VIDEO']}}}}}}


class ContractTests(unittest.TestCase):
    def check(self, change, status):
        old = contract()
        new = copy.deepcopy(old)
        change(new)
        result = MODULE.api_report(old, new)
        self.assertEqual(result['status'], status, result['failures'])

    def test_identical(self):
        self.check(lambda value: None, 'PASS')

    def test_optional_fields_and_enum_extensions(self):
        def change(value):
            schema = value['components']['schemas']['Asset']
            schema['properties']['deletedAt'] = {'type': 'string', 'nullable': True}
            schema['properties']['type']['enum'].append('MOTION')
        self.check(change, 'PASS')

    def test_optional_new_parameters(self):
        self.check(lambda value: value['paths']['/assets']['post']['parameters'].append(
            {'in': 'query', 'name': 'scope', 'required': False, 'schema': {'type': 'string'}}), 'PASS')

    def test_documentation_change(self):
        self.check(lambda value: value['components']['schemas']['Asset'].update({'description': 'Gallery'}), 'PASS')

    def test_operation_removed(self):
        self.check(lambda value: value['paths']['/assets'].pop('post'), 'FAIL')

    def test_operation_identity_changed(self):
        self.check(lambda value: value['paths']['/assets']['post'].update({'operationId': 'new'}), 'FAIL')

    def test_security_changed(self):
        self.check(lambda value: value['paths']['/assets']['post'].update({'security': []}), 'FAIL')

    def test_authentication_scheme_changed(self):
        self.check(lambda value: value['components']['securitySchemes']['api_key'].update({'name': 'new-key'}), 'FAIL')

    def test_property_removed(self):
        self.check(lambda value: value['components']['schemas']['Asset']['properties'].pop('id'), 'FAIL')

    def test_property_type_changed(self):
        self.check(lambda value: value['components']['schemas']['Asset']['properties']['id'].update({'type': 'integer'}), 'FAIL')

    def test_enum_value_removed(self):
        self.check(lambda value: value['components']['schemas']['Asset']['properties']['type']['enum'].remove('VIDEO'), 'FAIL')

    def test_new_required_field(self):
        self.check(lambda value: value['components']['schemas']['Asset']['required'].append('type'), 'FAIL')

    def test_required_constraint_added_to_previously_optional_object(self):
        old = contract()
        old['components']['schemas']['Asset'].pop('required')
        new = copy.deepcopy(old)
        new['components']['schemas']['Asset']['required'] = ['id']
        self.assertEqual(MODULE.api_report(old, new)['status'], 'FAIL')

    def test_new_string_validation_constraint_is_not_mistaken_for_an_additive_field(self):
        self.check(lambda value: value['components']['schemas']['Asset']['properties']['id'].update({'pattern': '^[a-z]+$'}), 'FAIL')

    def test_required_field_removed(self):
        self.check(lambda value: value['components']['schemas']['Asset']['required'].clear(), 'FAIL')

    def test_new_required_parameter(self):
        self.check(lambda value: value['paths']['/assets']['post']['parameters'].append(
            {'in': 'query', 'name': 'scope', 'required': True, 'schema': {'type': 'string'}}), 'FAIL')

    def test_response_removed(self):
        self.check(lambda value: value['paths']['/assets']['post']['responses'].pop('200'), 'FAIL')

    def test_request_content_type_removed(self):
        self.check(lambda value: value['paths']['/assets']['post']['requestBody']['content'].clear(), 'FAIL')


if __name__ == '__main__':
    unittest.main()
