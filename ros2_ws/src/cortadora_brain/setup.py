from setuptools import setup

package_name = 'cortadora_brain'

setup(
    name=package_name,
    version='0.0.1',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
         ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='Angel Alegre',
    maintainer_email='angel@example.com',
    description='Nodo principal de toma de decisiones para la cortadora',
    license='Apache-2.0',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            'bumper_decision_node = cortadora_brain.bumper_decision_node:main',
        ],
    },
)
