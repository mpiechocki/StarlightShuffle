"""Run inside Blender's Scripting workspace to import and save a native .blend.
Alternatively: blender --background --python import_to_blender.py
This helper requires Blender and has not been executed in this environment.
"""
import bpy
from pathlib import Path
from mathutils import Vector

folder=Path(__file__).resolve().parent
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath=str(folder/'pastel_lobby.glb'))
scene=bpy.context.scene
scene.unit_settings.system='METRIC'
scene.unit_settings.scale_length=1
scene.world.color=(.28,.23,.38)

def aim(obj,point):
    obj.rotation_euler=(Vector(point)-obj.location).to_track_quat('-Z','Y').to_euler()

bpy.ops.object.camera_add(location=(12,-19,14))
camera=bpy.context.object
camera.name='Lobby preview camera'
aim(camera,(0,1,1))
camera.data.type='ORTHO'
camera.data.ortho_scale=22
scene.camera=camera
for name,location,power,size in [
    ('Large soft key',(-4,-5,12),1800,10),
    ('Soft fill',(7,0,8),1000,8),
    ('Arcade rim',(-2,7,7),1200,6)]:
    bpy.ops.object.light_add(type='AREA',location=location)
    light=bpy.context.object
    light.name=name
    light.data.energy=power
    light.data.shape='DISK'
    light.data.size=size
    aim(light,(0,1,0))
scene.render.resolution_x=1600
scene.render.resolution_y=1100
scene.render.resolution_percentage=100
bpy.ops.wm.save_as_mainfile(filepath=str(folder/'pastel_lobby.blend'))
print('Saved native editable Blender scene:',folder/'pastel_lobby.blend')
