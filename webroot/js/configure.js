/**
 * Called when the MQTT connection is established
 */
function mqttConnected(message) {
	console.log("mqtt connected");
	mqtt.subscribe("flows/+/name");

}

/**
 * Called when the MQTT connection is lost
 * @param responseObject
 */
function mqttConnectionLost(responseObject) {
	if (responseObject.errorCode !== 0) {
		console.log("mqtt connect lost:" + responseObject.errorMessage);
	}
	mqtt.connect(mqttConnectionOptions);
}

var flows; // inited in setupConfigurePage
var matchFlowName = /flows\/(.*)\/name/;
var activeTab;
var desiredFlowID;

/**
 * Sort the flow tabs
 */
function sortFlows() {
	var sortedFlows = $('#flows').find("li").sort(function(a, b) {
		return a.id.localeCompare(b.id);
	});
	//update the sorted DOM
	$('#flows').find('ul').html(sortedFlows);
}

/**
 * Add a flow to the list of flows
 * @param flowID	the ID of the flow
 * @param flowName	the name of the flow
 */
function addFlowTab(flowID, flowName) {
	if (flowName.length == 0) {
		return;
	}

	console.log("Adding flow, id='" + flowID + "' name='" + flowName + "'");

	var tabTemplate = "<li id='#{id}'><a href='#{id}'>{label}</a> <span class='ui-icon ui-icon-close' role='presentation'>Remove Tab</span></li>";
	var li = $(tabTemplate.replace(/\{id\}/g, flowID).replace(
			/\{label\}/g, flowName));

	flows.find(".ui-tabs-nav").prepend(li);
	flows.append("<div id='" + flowID + "'><p>Flow " + flowName + "</p></div>");
	sortFlows();
	flows.tabs("refresh");
	if (desiredFlowID === flowID) {
		var tabIndex = $('#flows a[href="#' + flowID + '"]').parent().index();
		if (tabIndex >= 0) {
			flows.tabs("option", "active", tabIndex);
		}
	}
}

/**
 * Parse an incoming MQTT message
 * @param message the incoming Paho.MQTT.message
 */
function mqttHandleMessage(message) {
	console.log("mqtt received message: '" + message.destinationName + "'='"
			+ message.payloadString + "'");

	matches = message.destinationName.match(matchFlowName);
	if (matches) {
		addFlowTab(matches[1], message.payloadString);
	}
}

/**
 * Get the ID for a flow
 * @param flowName the name of the flow
 * @returns the ID of the flow
 */
function getFlowID(flowName) {
	return encodeURIComponent(flowName);
}

/**
 * Called when the create new flow form is submitted
 * Register the new flow with the MQTT broker
 * @param event the submit event
 */
function newFlowCreate(event) {
	event.preventDefault(); // prevent native submit
	flowName = $('#flowName').val();

	message = new Paho.MQTT.Message(flowName);
	flowID = getFlowID(flowName);
	message.destinationName = "flows/" + flowID + "/name";
	message.retained = true;

	mqtt.send(message);

	$("#newFlowDialog").dialog("close");
	desiredFlowID = flowID;
}

/**
 * Delete a flow
 * @param flow the id of the flow to delete
 */
function deleteFlow(flow) {
	message = new Paho.MQTT.Message('');
	message.destinationName = "flows/" + flow + "/name";
	message.retained = true;
	mqtt.send(message);
}

/**
 * Bind events on the configure page
 * @param mqttWebSocketHost	the MQTT websocket host
 * @param mqttWebSocketPort the MQTT websocket port
 */
function setupConfigurePage(mqttWebSocketHost, mqttWebSocketPort) {
	// Flow tabs

	flows = $("#flows").tabs({
		collapsible: true,
		active: false,
		beforeActivate: function (event, ui) {
			if (ui.newTab.attr('id') == 'zzzzzzz') {
				event.preventDefault();
				$("#newFlowDialog").dialog("open");
			} else {
				activeTab = ui.newTab.attr('id');
			}
		}
	});
	$("#menu").menu();

	$("#newFlowDialog").dialog({
		autoOpen : false,
		show : {
			effect : "blind",
			duration : 300
		},
		hide : {
			effect : "explode",
			duration : 300
		}
	});

	flows.on("click", "span.ui-icon-close", function() {
		var flowID = $(this).closest("li").remove().attr("aria-controls");
		deleteFlow(flowID);
		$("#" + flowID).remove();
		flows.tabs("refresh");
	});

	// MQTT connection
	mqtt = new Paho.MQTT.Client(mqttWebSocketHost, mqttWebSocketPort,
			"Uchisan Config");
	mqtt.onConnectionLost = mqttConnectionLost;
	mqtt.onMessageArrived = mqttHandleMessage;

	mqttConnectionOptions = {
		onSuccess : mqttConnected,
	};

	mqtt.connect(mqttConnectionOptions);

	// New Flow form
	$('#newFlowForm').on('submit', newFlowCreate);

	$('#flowName').keypress(function (e) {
	    var regex = /^[\w ]+$/;
	    var key = e.keyCode || e.charCode;
	    var str = String.fromCharCode(!e.charCode ? e.which : e.charCode);

	    if (key == 13) {
	    	newFlowCreate(e);
	    }

	    if (key == 8 || key == 46 || regex.test(str)) {
	        return true;
	    }

	    e.preventDefault();
	    return false;
	});


} // end of function() {

