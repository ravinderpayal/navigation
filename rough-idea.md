
- use google maps api
- use flutter
- call it Vinfast Copilot
- every time app starts, ask the user to enter battery SoC(State of the charge)
- ask for usual KWh per 100 km, give quick options like 15, 20, 25,30
- use this info and distance travelled to guestimate remaining SoC
- on app start, ask for where to go?
- show autocomplete as the user enters destination
- using maps api get the best route
- show the google maps kind of navigation interface
- make sure the app supports CarPlay(in its iOS version) and android auto(in its android version) projection out of the box

- when the guestimate charge drop below 50%, start showing ev-chargers falling on the route with big icons
- keeping ~25% charge for emergency, show the charger which would fall closest to the distance where battery would be approx 25%
- use the provided CSV sheet(VINFAST LIST_Free Charging Points_India_250726.csv) for the list of free chargers, optimise the stop/layover planning to utilise the chargers from this list
- plan for a detour upto 15kms on traffic free roads and upto 6kms in city for free chargers, beyond that a paid charger closer to where the car is or would be depending on SoC would be preferred
- integrate OCPP 2.0 to check if the charger is available or if busy then hopefully would be available by the time car would reach there based on average speed relative to congestion on highway and the situation ahead. unreachable/unavailable/dead-heartbeat chargers shouldn't be shown (optional, only if it's feasible without a lot of back and forth), and we don't need deep intergration, we just want if atleast the charger operator's server believes that charger is available, so that literally dead/abandoned chargers are not displayed/suggested to the users
- 