## Instructions

1. Implement a ticketing system in which multiple threads are invoked (the number is determined by command line arguments)
2. Each thread is given a ticket (number) and will wait until their ticket numbers have been called

# Observation
1. When `shared_variable[0] == ticket_number` the program enters an infinite loop. Explain why.
