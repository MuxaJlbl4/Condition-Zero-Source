import os
import random

# Predefined options for .cfg files
TASK1_OPTIONS = [
    "cz_task_add kill 10",
    "cz_task_add kill 5 inarow",
    "cz_task_add kill 3 survive",
    "cz_task_add killwith 2 pistol",
    "cz_task_add killwith 2 shotgun",
    "cz_task_add killwith 2 smg",
    "cz_task_add killwith 3 sniper",
    "cz_task_add killwith 3 rifle",
    "cz_task_add killwith 3 machinegun"
]

TASK2_OPTIONS = [
    "cz_task_add killwith 1 deagle survive",
    "cz_task_add killwith 1 scout survive",
    "cz_task_add killwith 3 sg550 inarow",
    "cz_task_add killwith 2 awp survive",
    "cz_task_add killwith 1 p90 survive",
    "cz_task_add killwith 3 m4a1 inarow",
    "cz_task_add killwith 2 aug survive",
    "cz_task_add killwith 3 m249 inarow"
]

TASK3_OPTIONS = [
    "cz_task_add spray 3",
    "cz_task_add winfast 60",
    "cz_task_add killwith 1 knife",
    "cz_task_add killblind 1",
    "cz_task_add killwith 1 hegrenade",
    "cz_task_add killvary 3 survive",
    "cz_task_add killvary 5 inarow"
]

# Predefined campaign config
CONFIG = "cz_matchwins\t3\ncz_matchwinsby\t2\n\nmp_startmoney\t16000"; 

def process_txt_files():
    for filename in os.listdir('.'):
        if filename.endswith('.txt') and os.path.isfile(filename):
            base_name = os.path.splitext(filename)[0].lower().replace(" ","_")
            
            # Create folder structure
            cfg_path = os.path.join(base_name, 'cfg', base_name)
            maps_path = os.path.join(base_name, 'maps', base_name)
            os.makedirs(cfg_path, exist_ok=True)
            os.makedirs(maps_path, exist_ok=True)
            
            # Read non-empty lines from txt file
            with open(filename, 'r') as f:
                lines = [line.strip() for line in f if line.strip()]
            
            # Create .cfg files and collect lines for macycle.txt
            macycle_lines = []
            for line in lines:
                cfg_file = os.path.join(cfg_path, f"{line}.cfg")
                
                # Generate random numbers
                opponents_num = random.randint(3, 10)
                teammates_num = opponents_num - random.randint(1, 3)
                
                # Write random tasks to cfg file
                with open(cfg_file, 'w') as cfg_f:
                    cfg_f.write(f"cz_opponents {opponents_num}\n")
                    cfg_f.write(f"cz_teammates {teammates_num}\n\n")
                    if (line.startswith("cs_") or line.startswith("de_")):
                        cfg_f.write(f"{random.choice(TASK1_OPTIONS)}\n")
                        cfg_f.write(f"{random.choice(TASK2_OPTIONS)}\n")
                        cfg_f.write(f"{random.choice(TASK3_OPTIONS)}\n")
                    else:
                        cfg_f.write(f"{random.choice(TASK1_OPTIONS[:2])}\n")
                        cfg_f.write(f"{random.choice(TASK3_OPTIONS[:2])}\n")
                
                macycle_lines.append(line)
            
            # Create macycle.txt
            if macycle_lines:
                with open(os.path.join(cfg_path, 'mapcycle.txt'), 'w') as f:
                    f.write('\n'.join(macycle_lines))
            
            # Create campaign config
            if macycle_lines:
                with open(os.path.join(cfg_path, 'campaign.cfg'), 'w') as f:
                    f.write(CONFIG)

            # Create folderinfo.bns
            with open(os.path.join(maps_path, 'folderinfo.bns'), 'w') as f:
                f.write(f"\"{base_name.replace("_"," ").title()}\"\n{{\n\t\"image\"\t\t\"{base_name}.tga\"\n\t\"comment\"\t\"{base_name.replace("_"," ").title()}\"\n}}")
            
            # Create campaign.bns with formatted mission names
            with open(os.path.join(maps_path, 'campaign.bns'), 'w') as f:
                for line in lines:
                    mission_name = get_mission_name(line)
                    f.write(f"\"{mission_name}\"\n{{\n\t\"map\"\t\t\"{line}; hostname {base_name}\"\n\t\"image\"\t\t\"maps/{line}.tga\"\n\t\"comment\"\t\"{line}\"\n}}\n")

def get_mission_name(map_name):
    # Split remaining name and take first meaningful part
    if '_' in map_name:
        map_name = map_name.split('_')[1]

    # Capitalize first letter
    return map_name.capitalize()


if __name__ == "__main__":
    process_txt_files()