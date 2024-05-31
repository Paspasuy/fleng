aboba: fleng

#main.elf: main.o Chess.o ChessView.o
#	g++ main.o Chess.o ChessView.o -o main.elf

#main.o: main.cpp Chess.h ChessView.h
#	g++ -c main.cpp -o main.o

#Chess.o: Chess.cpp Chess.h
#	g++ -c Chess.cpp -o Chess.o

#ChessView.o: ChessView.cpp ChessView.h
#	g++ -c ChessView.cpp -o ChessView.o
fleng.o: fleng.cpp
	g++ -c fleng.cpp
fleng: fleng.o
	g++ fleng.o -o fleng.elf -lsfml-graphics -lsfml-window -lsfml-system


# build: normal_mapping.elf# raycast.elf trolling.elf

clean:
	rm -rf *.elf *.o
