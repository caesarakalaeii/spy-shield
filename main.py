"""
GeoIP Redirect Service

This service redirects users based on their country of origin using GeoIP data. 
Users from Pakistan or India will be redirected to an alternative server, while users from other countries will be redirected to a default subdomain.

Dependencies:
- quart: An asynchronous web microframework for Python.

"""

import ipaddress
from json import JSONDecodeError
import requests
import httpx
from logger import Logger
from json_handler import *
from quart import Quart, jsonify, redirect, render_template, request, send_file

app = Quart(__name__)
l = Logger(console_log= True, file_logging=True, file_URI='logs/log.txt', override=True)
default_server:str
alternative_server_url:str
test_flag:bool
redirected:bool
config:dict
id_list:list

@app.route('/', methods=['GET', 'POST'])
async def index():
    try:
        if request.method == 'POST':
        
            form_data = await request.form
            id = form_data.get('id', None)
            
            # Add the ID to the list
            if not id in id_list:
                id_list.append(id)
                write_to_json_file(id_list, 'tracked_ids.json')
            
            # Redirect to the same page
            data = await request_data(id)
            msg = ''
            
            if data:
                msg = f'Your server is being tracked!\nCurrent user appears to be : {data}'
            else:
                msg = 'You Server is not actively being tracked'
            return await render_template('index.html', message=f'ID added successfully!\n{msg}')
        
    except JSONDecodeError as e:
        return await render_template('index.html', message=f'You need to provide a DC Server ID')
    # If it's a GET request, just render the form
    return await render_template('index.html', message=None)


async def request_data(dc_id):
    async with httpx.AsyncClient() as client:
        response = await client.get(config['api_endpoint'] + dc_id)
        data = response.json()
    
    if data:
        return data['onAccount']
    else:
        return False
        

   
@app.route('/api/<path:dc_id>')
async def refer(dc_id):
    return request_data(dc_id)
        
        


# Route for serving favicon.ico
@app.route('/favicon.ico')
async def favicon():
    return await send_file('favicon.ico')

if __name__ == '__main__':
    
    id_list = []
    config = read_json_file('config.json')
    test_flag = config['test_flag']
    redirected = False
    if test_flag:
        l.passing('Test flag is set, every second request will be directed to the honey pot')

    
    app_port = int(config['app_port'])
    
    
    app.run(host='0.0.0.0',port = app_port)