// RoomOS Macro to create a touch panel button that sends a webhook with the device display name

// Setup Instructions:
// Replace 'WEBHOOK_URL' with your actual webhook endpoint URL.
// You can customize the button appearance by changing:
// BUTTON_NAME: The text that appears on the button
// icon: The icon displayed (options include 'Webex', 'Handset', etc.)
// color: The button color in hex format
// Upload this macro to your Cisco device via the web interface:
  // Access your device's Cisco admin web interface
  // Go to Integration > Macro Editor
  // Create a new macro and paste the code below
  // Save and enable the macro
  // The macro will create a persistent button on the home screen that sends the device name (which should be the room name) as a text body to your webhook endpoint when pressed.


const xapi = require('xapi');

// Configuration
const WEBHOOK_URL = 'https://_____/api/engine/v2/webhook/trig-IUWnbJR24C/notify/______________/Webhook/1/receive_webhook';
const BUTTON_NAME = 'Request Assistance';
const PANEL_ID = 'webhook_button';

// Create the touch panel button
function createPanel() {
  const panel = {
    panelId: PANEL_ID,
    type: 'Home',
    persistent: true,
    icon: 'Webex',
    color: '#0000FF',
    name: BUTTON_NAME,
    activityType: 'Custom'
  };

  xapi.command('UserInterface Extensions Panel Save', panel)
    .then(() => {
      console.log('Panel created successfully');
    })
    .catch((error) => {
      console.error('Error creating panel:', error.message);
    });
}

// Get the device display name
async function getDeviceDisplayName() {
  try {
    const config = await xapi.config.get('SystemUnit Name');
    return config;
  } catch (error) {
    console.error('Error getting device name:', error.message);
    return 'Unknown Device';
  }
}

// Send the webhook with device display name
async function sendWebhook() {
  try {
    // Get the device display name
    const displayName = await getDeviceDisplayName();
    
    // Send the webhook with the display name
    await xapi.command('HttpClient Post', {
      Url: WEBHOOK_URL,
      Header: ['Content-Type: text/plain'],
      Body: displayName
    });
    
    console.log('Webhook sent successfully with device name:', displayName);
    
    // Show feedback to user
    xapi.command('UserInterface Message Alert Display', {
      Title: 'Success',
      Text: 'Webhook sent with device name',
      Duration: 5
    });
  } catch (error) {
    console.error('Failed to send webhook:', error.message);
    xapi.command('UserInterface Message Alert Display', {
      Title: 'Error',
      Text: 'Failed to send webhook',
      Duration: 5
    });
  }
}

// Event listener for panel clicks
function listenForPanelClicks() {
  xapi.event.on('UserInterface Extensions Panel Clicked', (event) => {
    if (event.PanelId === PANEL_ID) {
      console.log('Webhook button clicked');
      sendWebhook();
    }
  });
}

// Initialize the macro
function init() {
  createPanel();
  listenForPanelClicks();
  console.log('Webhook button macro initialized');
}

init();