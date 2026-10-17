import unittest

import src_peter as P


class Pages(unittest.TestCase):
    def test_lines_in_crop_order_either_attribute_form(self):
        coco = {'images': [{'id': 7, 'file_name': '3_2.jpg'}],
                'annotations': [
                    {'image_id': '7', 'matched_crop_name': '3_2_10.jpg', 'attributes': "{'translation': 'третья'}"},
                    {'image_id': '7', 'matched_crop_name': '3_2_2.jpg', 'attributes': {'translation': 'вторая'}},
                    {'image_id': '7', 'matched_crop_name': '3_2_0.jpg', 'attributes': "{'translation': ' первая '}"},
                    {'image_id': '7', 'matched_crop_name': '3_2_1.jpg', 'attributes': "{'translation': ''}"},
                    {'image_id': '9', 'matched_crop_name': '4_1_0.jpg', 'attributes': "{'translation': 'чужая'}"}]}
        self.assertEqual(P.pages(coco), {'3_2.jpg': 'первая\nвторая\nтретья'})


if __name__ == '__main__':
    unittest.main()
