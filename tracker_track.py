
import asyncio
import httpx
from logger import Logger
from json_handler import *
import requests

config:dict

def send_to_channel(message:str):
    """
    Sends a message using Discord webhook.

    Args:
    - message (str): The message to send.
    - webhook_url (str): The URL of the Discord webhook.

    Returns:
    - bool: True if the message was sent successfully, False otherwise.
    """
    global config
    
    # Create payload
    payload = {
        "content": message
    }

    try:
        # Send POST request to the webhook URL
        response = requests.post(config["dc_webhook_url"], json=payload)
        response.raise_for_status()  # Raise an exception for any HTTP error status

        # Check if the message was sent successfully
        if response.status_code == 204:
            l.passing("Message sent successfully")
            return True
        else:
            l.error(f"Failed to send message. Status code: {response.status_code}")
            return False
    except requests.exceptions.RequestException as e:
        l.error(f"Failed to send message: {e}")
        return False
    
    
async def request_data(dc_id):
    async with httpx.AsyncClient() as client:
        response = await client.get(config['api_endpoint'] + dc_id)
        data = response.json()
    
    if data:
        return data['onAccount']
    else:
        return False
    
async def main_loop():
    while True:
        l.passingblue('Preparing new batch of requests')
        tracked_ids = read_json_file('tracked_ids.json')
        l.passing(f'Currently tracked IDs are: {tracked_ids}')
        for id in tracked_ids:
            res = await request_data(id)
            try:
                if current_users[id] == res:
                    continue
                if res:
                    current_users[id] = res
                    l.warning(f'User for ID {id} has changed to: {res}')
                    await send_to_channel(f'User for ID {id} has changed to: {res}')
                if not res:
                    l.passing(f'Server {id} is no longer tracked!')
                    await send_to_channel(f'Server {id} is no longer tracked!')
            except KeyError:
                if res:
                    l.warning(f'New ID {id} has been added, User is: {res}')
                else:
                    l.warning(f'New ID {id} has been added, not tracked atm!')
                current_users.update({id:res})
        
        await asyncio.sleep(600) #wait 10 mins for next batch
                
                

if __name__ == '__main__':
    l = Logger(True, False)
    config = read_json_file('config.json')
    current_users = {}
    asyncio.run(main_loop())
    
    
        
    